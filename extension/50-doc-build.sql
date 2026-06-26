-- =====================================================================
-- 50-doc-build.sql — Arc B: generate documents IN the coder sandbox.
-- =====================================================================
-- The read↔write twin of doc-extract. doc-extract turns an uploaded file into
-- text; doc-build turns a request + source material into a real, downloadable
-- artifact (PDF / xlsx / pptx / docx / images / zip). The engine is the existing
-- coder sandbox — now equipped with a document toolchain (extension/
-- coder-runtime.Dockerfile: python-docx/pptx, openpyxl, reportlab, Pillow,
-- markdown + pandoc + wkhtmltopdf) — driven model-in-the-loop: the agent writes
-- a generator script, runs it, and exports the file via coder_export_artifact
-- (coder-mcp, Arc B). "Programming + these libs = infinite document output,"
-- including zip bundles for corpus exports.
--
-- Spawnable from a Stewdio chat via start_task (the chat's Delegate / the
-- /generate slash command), so the user can chat about the document while it
-- builds and watch the stages in the plan=progress panel. The generated artifact
-- lands as a downloadable chat_attachments row (the /api/chat/attachment/{id}
-- serve endpoint) and the export tool returns its URL.
--
-- requires create_doc_extract (49). Needs the coder overlay (docker socket +
-- coder-runtime image) to RUN; the pipeline + grant seed regardless (like code-pr).
-- =====================================================================

-- ── §1 — grant the artifact-export tool to the dev (coder) agent ────
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('dev', 'coder_export_artifact', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ── §2 — the doc-build pipeline (plan → build → deliver) ────────────
-- Portable: the standard bgworker tool loop + the coder MCP tools, on a role-
-- alias model ('reason' → the local rig in a work instance via the overlay), so
-- it runs locally with no special coder harness. promote_to_doc stays false —
-- the deliverable is a downloadable FILE, not a pooled markdown doc.
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, file_destination_template, file_content_jsonpath, maturity_ladder) VALUES
('doc-build',
 'Generate a real document (PDF / xlsx / pptx / docx / image / zip) in the coder sandbox from a request + source material, and export it as a downloadable artifact.',
 $stages$[
   {"name":"plan","next":"build","model":"reason","agent_family":"dev","auto_advance":true,"tools_disabled":true,
    "input_template":"You are planning a DOCUMENT to generate (not code). Request:\n{{input.binding_question}}\n\n(Any source material the user attached is already included in the request above.) Decide: (1) the output FORMAT(s) — pdf / xlsx / pptx / docx / png / a zip bundle — fit to the request; (2) the structure / sections / sheets / slides; (3) any branding or template to honor if named; (4) the generator approach — which Python library (python-docx, python-pptx, openpyxl, reportlab, Pillow) or pandoc/wkhtmltopdf, and a brief script outline. If the request needs facts from our corpus, note what to pull with doc_search in the build step. Keep it tight; the build step implements this."},
   {"name":"build","next":"deliver","model":"reason","agent_family":"dev","auto_advance":true,"tools_disabled":false,
    "input_template":"Generate the document in the sandbox, using the plan:\n{{stage_results.plan.output}}\n\nRequest: {{input.binding_question}}\nYour sandbox id: {{input.sandbox}}\n\nSteps:\n1. coder_sandbox_start with sandbox=\"{{input.sandbox}}\".\n2. If you need facts/quotes from our corpus, gather them first with doc_search.\n3. coder_write a generator script, then coder_shell to run it. GENERATION RECIPES — pick the simplest that fits and keep styling MINIMAL (fancy/obscure style attributes cause error loops):\n   • PDF: reportlab SimpleDocTemplate + Paragraph/Table using getSampleStyleSheet() — do NOT invent style kwargs; OR write clean HTML and run `wkhtmltopdf in.html out.pdf`.\n   • DOCX: python-docx, OR write markdown and run `pandoc in.md -o out.docx`.\n   • XLSX: openpyxl.  • PPTX: python-pptx.  • Images: Pillow.  • Multiple files → zip with Python zipfile.\n   (pandoc + wkhtmltopdf are on PATH; paths are relative to /work.)\n4. ITERATE: if coder_shell exits non-zero, read the traceback, fix the script, re-run until it exits 0 AND the file exists. Prefer the simplest working approach over a prettier one that keeps erroring. EDIT-LOOP GUARD: if coder_edit reports an old_string is ambiguous ('appears N times') or not found, do NOT repeat the same edit — set replace_all=true, use a longer UNIQUE anchor, or coder_write the WHOLE file fresh. Never repeat a failing edit more than once; rewrite the file rather than loop. If a clean run won't come after a few tries, coder_write a minimal version that exports SOMETHING rather than nothing.\n5. coder_export_artifact with sandbox=\"{{input.sandbox}}\", path=\"<the generated file>\", session_id=\"{{input.spawned_from_chat}}\", a clear filename. Multiple files → zip first, export the zip.\n\nEND your report with the EXACT download URL the export tool returned, on its own final line, formatted as:\nDownload: <url>"},
   {"name":"deliver","next":null,"model":"reason","agent_family":"dev","auto_advance":true,"tools_disabled":true,
    "input_template":"A document was generated + exported by the build step. Its report — which ENDS with the real download URL on a 'Download:' line — is below:\n{{stage_results.build.output}}\n\nWrite a short delivery note for the user: what the document contains, its format, and the download link — copy the EXACT Download: URL from the build report above. The artifact is real and already stored server-side; do NOT say you can't access, reach, or verify it. Only if the build report shows a FAILURE (no Download: URL) do you say it failed and what to adjust."}
 ]$stages$::jsonb,
 'f','f',NULL,NULL,'["raw","planned","executing","verified"]'::jsonb)
ON CONFLICT (family) DO UPDATE SET
   stages=EXCLUDED.stages, description=EXCLUDED.description,
   sabbath_enabled=EXCLUDED.sabbath_enabled, atonement_enabled=EXCLUDED.atonement_enabled,
   maturity_ladder=EXCLUDED.maturity_ladder;

-- =====================================================================
-- End of 50-doc-build.sql
-- =====================================================================
