#!/usr/bin/env bash
# Deterministic oracle for the Stewdio Details toggle (streamline S4/S5 + the
# Details-mode build). "One surface, two depths": OFF is the clean everyday
# surface; ON (⚙ Details) reveals the live Activity pane (models / tokens /
# dispatch stream), inline tool-call detail, and the developer/raw surfaces.
# Asserted in BOTH directions (inverse hypothesis: OFF hides -> ON shows ->
# OFF hides again — the Models/Activity-pane leak the fan-out once found).
#
# NOTE: the live "working" pulse (the no-thinking-badge fix) needs a real
# in-flight turn, so it is verified live (manual + the QA workflow), not here.
# This oracle covers the deterministic surfaces.
set -u
UI="${UI:-http://127.0.0.1:8081/stewdio}"
PASS=0; FAIL=0
chk(){ if [ "$3" = "$2" ]; then echo "  OK  $1"; PASS=$((PASS+1)); else echo "  XX  $1 (exp=$2 got=$3)"; FAIL=$((FAIL+1)); fi; }
ev(){ playwright-cli --raw eval "$1" 2>/dev/null | tail -1; }

playwright-cli close >/dev/null 2>&1
playwright-cli open "$UI" >/dev/null 2>&1; sleep 3
# clean default: clear our persisted dev flag + the saved layout (so the renamed
# default rebuilds), then reload.
playwright-cli --raw eval "localStorage.removeItem('stewdio.dev'); localStorage.removeItem('stewdio.layout.v3'); 'ok'" >/dev/null 2>&1
playwright-cli reload >/dev/null 2>&1; sleep 3
# give the chat a grounding target so its header renders (the '+ New chat' button
# is v-if="chatRef"). Set the lens select to '✸ Everything' (__all__) → chatRef='all'.
playwright-cli --raw eval "(function(){var s=[...document.querySelectorAll('select')].find(el=>[...el.options].some(o=>o.value==='__all__')); if(s){s.value='__all__'; s.dispatchEvent(new Event('change',{bubbles:true})); return 'set'} return 'none'})()" >/dev/null 2>&1; sleep 2

echo "== Details OFF (everyday surface, default) =="
chk "Details toggle present"      true  "$(ev "!!document.querySelector('button[title*=\"Details mode\"]')")"
chk "panel titled 'Library'"      true  "$(ev "document.body.innerText.includes('Library')")"
chk "'New chat' label present"    true  "$(ev "document.body.innerText.includes('New chat')")"
chk "'New task' label present"    true  "$(ev "document.body.innerText.includes('New task')")"
chk "model-role select HIDDEN"    false "$(ev "!!document.querySelector('option[value=\"critic\"]')")"
playwright-cli click "getByText('▦ panels')" >/dev/null 2>&1; sleep 1
chk "Activity pane HIDDEN (launcher)" false "$(ev "[...document.querySelectorAll('button')].some(b=>b.textContent.trim()==='Activity')")"
playwright-cli click "getByText('▦ panels')" >/dev/null 2>&1; sleep 1

echo "== toggle Details ON + OPEN the Activity (details) pane =="
playwright-cli click "getByText('⚙ Details')" >/dev/null 2>&1; sleep 1
chk "model-role select SHOWN"     true  "$(ev "!!document.querySelector('option[value=\"critic\"]')")"
chk "vision role option present"  true  "$(ev "!!document.querySelector('option[value=\"vision\"]')")"
playwright-cli click "getByText('▦ panels')" >/dev/null 2>&1; sleep 1
chk "Activity pane in launcher"   true  "$(ev "[...document.querySelectorAll('button')].some(b=>b.textContent.trim()==='Activity')")"
# open the Activity pane via the launcher button (getByRole button, not the nav <a> link)
playwright-cli click "getByRole('button', { name: 'Activity', exact: true })" >/dev/null 2>&1; sleep 2
chk "Activity pane MOUNTED (Running now)"  true "$(ev "document.body.innerText.toLowerCase().includes('running now')")"
chk "live token stream present (Live dispatches)" true "$(ev "document.body.innerText.toLowerCase().includes('live dispatches')")"

echo "== toggle Details OFF again (inverse hypothesis — the leak the fan-out found) =="
playwright-cli click "getByText('⚙ Details')" >/dev/null 2>&1; sleep 1
chk "model-role select HIDDEN again"     false "$(ev "!!document.querySelector('option[value=\"critic\"]')")"
chk "Activity pane CLOSED on Details OFF" false "$(ev "document.body.innerText.toLowerCase().includes('live dispatches')")"
chk "dev flag persisted false"           false "$(ev "JSON.parse(localStorage.getItem('stewdio.dev')||'false')")"

echo "== S5 intent-named launcher (everyday surface, Details off) =="
playwright-cli --raw eval "(function(){var b=[...document.querySelectorAll('button')].find(x=>x.textContent.trim().startsWith('＋ New task')); if(b){b.click();return 'ok'} return 'none'})()" >/dev/null 2>&1; sleep 1
chk "verb: Research"                       true  "$(ev "[...document.querySelectorAll('button')].some(b=>b.textContent.includes('Research'))")"
chk "verb: Generate"                       true  "$(ev "[...document.querySelectorAll('button')].some(b=>b.textContent.includes('Generate'))")"
chk "Build verb DROPPED (needs a form)"    false "$(ev "[...document.querySelectorAll('button')].some(b=>b.textContent.includes('Build'))")"
chk "raw families HIDDEN by default"       false "$(ev "!!document.querySelector('option[value=\"brainstorm-six-hats\"]')")"
chk "'more pipelines' is Details-only (hidden)" false "$(ev "[...document.querySelectorAll('button')].some(b=>b.textContent.includes('more pipelines'))")"
playwright-cli --raw eval "(function(){var b=[...document.querySelectorAll('button')].find(x=>x.textContent.includes('Research')); if(b){b.click();return 'ok'} return 'none'})()" >/dev/null 2>&1; sleep 1
chk "picking Research sets a pipeline"     true  "$(ev "document.body.innerText.includes('research-write')")"

playwright-cli close >/dev/null 2>&1
echo "---- $PASS passed, $FAIL failed ----"
[ "$FAIL" = "0" ]
