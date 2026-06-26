// generate_image — text-to-image via Google Gemini (Nano Banana /
// gemini-2.5-flash-image), stored as a chat_attachment (kind=image) so it
// renders inline in the chat and rides the rich artifact cards. A core tool
// (always available; NOT on the read-only remote profile in http.go). Reads the
// google_gemini provider key from the bridge env it inherits.
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type GenerateImageInput struct {
	Prompt    string `json:"prompt" jsonschema:"what to draw / generate (be specific about subject, style, framing)"`
	SessionID string `json:"session_id" jsonschema:"the chat/work session id to attach the image to, so it shows in that conversation"`
	Filename  string `json:"filename,omitempty" jsonschema:"optional filename (default generated.png)"`
	Model     string `json:"model,omitempty" jsonschema:"image model; default gemini-2.5-flash-image (Nano Banana)"`
}

type GenerateImageOutput struct {
	URL      string `json:"url"`
	ID       int64  `json:"id"`
	MimeType string `json:"mime_type"`
	Bytes    int    `json:"bytes"`
}

func registerImageTools(srv *mcp.Server, pool *pgxpool.Pool) {
	if pool == nil {
		return
	}
	mcp.AddTool(srv, &mcp.Tool{
		Name: "generate_image",
		Description: "Generate an image from a text prompt with Google Gemini (Nano Banana) and store it as a " +
			"downloadable attachment in the chat session, so it renders inline. Use for diagrams, illustrations, " +
			"icons, mockups, or any picture the user asks for. Pass session_id = the chat/work session. Returns the " +
			"image URL. Requires the google_gemini provider key (a PAID/Vertex key for confidential content — an " +
			"AI-Studio free key trains on the prompt).",
	}, makeGenerateImage(pool))
}

func makeGenerateImage(pool *pgxpool.Pool) func(context.Context, *mcp.CallToolRequest, GenerateImageInput) (*mcp.CallToolResult, GenerateImageOutput, error) {
	return func(ctx context.Context, _ *mcp.CallToolRequest, in GenerateImageInput) (*mcp.CallToolResult, GenerateImageOutput, error) {
		if strings.TrimSpace(in.Prompt) == "" {
			return toolError("generate_image: prompt is required"), GenerateImageOutput{}, nil
		}
		key := strings.TrimSpace(os.Getenv("STEWARDS_PROVIDER_GOOGLE_GEMINI_API_KEY"))
		if key == "" {
			return toolError("generate_image: STEWARDS_PROVIDER_GOOGLE_GEMINI_API_KEY not set — wire the google_gemini provider"), GenerateImageOutput{}, nil
		}
		// derive the NATIVE base from the OpenAI-compat base (strip /openai); the
		// image path is generateContent, not on the openai-compat surface.
		base := strings.TrimRight(os.Getenv("STEWARDS_PROVIDER_GOOGLE_GEMINI_BASE_URL"), "/")
		if base == "" {
			base = "https://generativelanguage.googleapis.com/v1beta"
		}
		base = strings.TrimSuffix(base, "/openai")
		model := in.Model
		if model == "" {
			model = "gemini-2.5-flash-image"
		}

		reqBody, _ := json.Marshal(map[string]any{
			"contents":         []any{map[string]any{"parts": []any{map[string]any{"text": in.Prompt}}}},
			"generationConfig": map[string]any{"responseModalities": []string{"IMAGE"}},
		})
		cctx, cancel := context.WithTimeout(ctx, 90*time.Second)
		defer cancel()
		// Cost ceiling: image gen bypasses the chat dispatch gate (compose_messages
		// Layer-1), so honor the provider spend cap here too — otherwise it's an uncapped
		// spend path. provider = google_gemini (the provider this tool dials). On an
		// install with no enforced cap, provider_cap_exceeded is false → no-op.
		const imgProvider = "google_gemini"
		var capExceeded bool
		if err := pool.QueryRow(cctx, `SELECT stewards.provider_cap_exceeded($1)`, imgProvider).Scan(&capExceeded); err == nil && capExceeded {
			return toolError("generate_image: %s spend cap reached — image generation blocked (provider_spend_caps); refill or raise the cap to resume", imgProvider), GenerateImageOutput{}, nil
		}
		url := fmt.Sprintf("%s/models/%s:generateContent?key=%s", base, model, key)
		httpReq, _ := http.NewRequestWithContext(cctx, http.MethodPost, url, bytes.NewReader(reqBody))
		httpReq.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(httpReq)
		if err != nil {
			return toolError("generate_image: gemini call: %v", err), GenerateImageOutput{}, nil
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		if resp.StatusCode/100 != 2 {
			b := string(body)
			if len(b) > 200 {
				b = b[:200]
			}
			return toolError("generate_image: gemini HTTP %d: %s", resp.StatusCode, b), GenerateImageOutput{}, nil
		}

		var parsed struct {
			Candidates []struct {
				Content struct {
					Parts []struct {
						InlineData struct {
							MimeType string `json:"mimeType"`
							Data     string `json:"data"`
						} `json:"inlineData"`
					} `json:"parts"`
				} `json:"content"`
			} `json:"candidates"`
		}
		if err := json.Unmarshal(body, &parsed); err != nil {
			return toolError("generate_image: decode response: %v", err), GenerateImageOutput{}, nil
		}
		var img []byte
		var mime string
		for _, c := range parsed.Candidates {
			for _, p := range c.Content.Parts {
				if p.InlineData.Data != "" {
					if d, derr := base64.StdEncoding.DecodeString(p.InlineData.Data); derr == nil {
						img, mime = d, p.InlineData.MimeType
					}
					break
				}
			}
			if img != nil {
				break
			}
		}
		if len(img) == 0 {
			return toolError("generate_image: no image in the response (model=%s — try a more concrete prompt)", model), GenerateImageOutput{}, nil
		}
		if mime == "" {
			mime = "image/png"
		}
		fn := strings.TrimSpace(in.Filename)
		if fn == "" {
			fn = "generated.png"
		}
		sess := strings.TrimSpace(in.SessionID)
		if sess == "" {
			sess = "images"
		}
		var id int64
		if err := pool.QueryRow(cctx,
			`INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, bytes, byte_size)
			 VALUES ($1, $2, $3, 'image', $4, $5) RETURNING id`,
			sess, fn, mime, img, len(img),
		).Scan(&id); err != nil {
			return toolError("generate_image: store attachment: %v", err), GenerateImageOutput{}, nil
		}
		serveURL := fmt.Sprintf("/api/chat/attachment/%d", id)
		// Record the spend so image generation shows up in provider_spend_caps + cost
		// reporting (it doesn't go through the chat cost path, so it was invisible). Nano
		// Banana is billed per image; flat default, override via config image_cost_micro_dollars.
		var costMicro int64 = 39000 // ~$0.039 / image
		_ = pool.QueryRow(cctx,
			`SELECT coalesce((value #>> '{}')::bigint, 39000) FROM stewards.config WHERE key = 'image_cost_micro_dollars'`,
		).Scan(&costMicro)
		if _, cerr := pool.Exec(cctx,
			`INSERT INTO stewards.cost_events (session_id, attempt_seq, provider, model, output_tokens, micro_dollars, pricing_effective_at, notes)
			 VALUES ($1, 1, $2, $3, 0, $4, now(), 'generate_image (Nano Banana) per-image cost')`,
			sess, imgProvider, model, costMicro); cerr != nil {
			fmt.Fprintf(os.Stderr, "generate_image: cost_event insert failed (image still served): %v\n", cerr)
		}
		out := GenerateImageOutput{URL: serveURL, ID: id, MimeType: mime, Bytes: len(img)}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{
			Text: fmt.Sprintf("Generated image (%s, %d bytes). View / download: %s", mime, len(img), serveURL),
		}}}, out, nil
	}
}
