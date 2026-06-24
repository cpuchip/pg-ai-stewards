#!/usr/bin/env bash
# Deterministic oracle for the Stewdio Developer toggle (streamline S4).
# Asserts the "one surface, two depths" invariants in BOTH directions
# (inverse hypothesis: OFF hides the dev surfaces -> ON shows them -> OFF hides again).
set -u
UI="${UI:-http://127.0.0.1:8081/stewdio}"
PASS=0; FAIL=0
chk(){ if [ "$3" = "$2" ]; then echo "  OK  $1"; PASS=$((PASS+1)); else echo "  XX  $1 (exp=$2 got=$3)"; FAIL=$((FAIL+1)); fi; }
ev(){ playwright-cli --raw eval "$1" 2>/dev/null | tail -1; }

playwright-cli close >/dev/null 2>&1
playwright-cli open "$UI" >/dev/null 2>&1; sleep 3
# clean default: clear our persisted dev flag + the saved layout (so the renamed
# 'Library' default rebuilds), then reload.
playwright-cli --raw eval "localStorage.removeItem('stewdio.dev'); localStorage.removeItem('stewdio.layout.v2'); 'ok'" >/dev/null 2>&1
playwright-cli reload >/dev/null 2>&1; sleep 3
# give the chat a grounding target so its header renders (the '+ New chat' button
# is v-if="chatRef"). Set the lens select to '✸ Everything' (__all__) → chatRef='all'.
playwright-cli --raw eval "(function(){var s=[...document.querySelectorAll('select')].find(el=>[...el.options].some(o=>o.value==='__all__')); if(s){s.value='__all__'; s.dispatchEvent(new Event('change',{bubbles:true})); return 'set'} return 'none'})()" >/dev/null 2>&1; sleep 2

echo "== Dev OFF (everyday surface, default) =="
chk "Dev toggle present"          true  "$(ev "!!document.querySelector('button[title*=\"Developer mode\"]')")"
chk "panel titled 'Library'"      true  "$(ev "document.body.innerText.includes('Library')")"
chk "'New chat' label present"    true  "$(ev "document.body.innerText.includes('New chat')")"
chk "'New task' label present"    true  "$(ev "document.body.innerText.includes('New task')")"
chk "model-role select HIDDEN"    false "$(ev "!!document.querySelector('option[value=\"critic\"]')")"
playwright-cli click "getByText('▦ panels')" >/dev/null 2>&1; sleep 1
chk "Models pane HIDDEN (launcher)" false "$(ev "[...document.querySelectorAll('button')].some(b=>b.textContent.trim()==='Models')")"
playwright-cli click "getByText('▦ panels')" >/dev/null 2>&1; sleep 1

echo "== toggle Dev ON + OPEN the Models (dev) pane =="
playwright-cli click "getByText('⚙ Dev')" >/dev/null 2>&1; sleep 1
chk "model-role select SHOWN"     true  "$(ev "!!document.querySelector('option[value=\"critic\"]')")"
chk "vision role option present"  true  "$(ev "!!document.querySelector('option[value=\"vision\"]')")"
playwright-cli click "getByText('▦ panels')" >/dev/null 2>&1; sleep 1
chk "Models pane in launcher"     true  "$(ev "[...document.querySelectorAll('button')].some(b=>b.textContent.trim()==='Models')")"
# open the Models pane via the launcher button (getByRole button, not the nav <a> link)
playwright-cli click "getByRole('button', { name: 'Models', exact: true })" >/dev/null 2>&1; sleep 2
chk "Models pane MOUNTED (Running now)" true "$(ev "document.body.innerText.toLowerCase().includes('running now')")"

echo "== toggle Dev OFF again (inverse hypothesis — the leak the fan-out found) =="
playwright-cli click "getByText('⚙ Dev')" >/dev/null 2>&1; sleep 1
chk "model-role select HIDDEN again"   false "$(ev "!!document.querySelector('option[value=\"critic\"]')")"
chk "Models pane CLOSED on Dev OFF"    false "$(ev "document.body.innerText.toLowerCase().includes('running now')")"
chk "dev flag persisted false"         false "$(ev "JSON.parse(localStorage.getItem('stewdio.dev')||'false')")"

playwright-cli close >/dev/null 2>&1
echo "---- $PASS passed, $FAIL failed ----"
[ "$FAIL" = "0" ]
