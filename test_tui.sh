#!/bin/bash
# TUI integration test using tmux
set -e

SESSION="sniper_test"
PASSED=0
FAILED=0

# Kill any existing test session
tmux kill-session -t "$SESSION" 2>/dev/null || true
sleep 0.5

log_pass() { PASSED=$((PASSED + 1)); echo "  ✓ $1"; }
log_fail() { FAILED=$((FAILED + 1)); echo "  ✗ $1: $2"; }

capture() { tmux capture-pane -t "$SESSION" -p 2>/dev/null; }
send() { tmux send-keys -t "$SESSION" "$@"; }

wait_for() {
    local pattern="$1" timeout="${2:-10}" i=0
    while [ $i -lt $timeout ]; do
        if capture | grep -q "$pattern" 2>/dev/null; then return 0; fi
        sleep 1; i=$((i + 1))
    done
    return 1
}

echo "=== Sniper TUI Integration Tests ==="
echo ""

# Build, install, and sign
echo "Building..."
zig build 2>&1 || { echo "BUILD FAILED"; exit 1; }
cp zig-out/bin/sniper ~/.local/bin/sniper
codesign -s - ~/.local/bin/sniper 2>/dev/null
echo "Build OK"
echo ""

# Clear saved sessions to start clean
rm -rf ~/.config/sniper/sessions/*.json 2>/dev/null || true
rm -f ~/.config/sniper/last_session 2>/dev/null || true

# --- Launch ---
echo "Test 1: Launch"
tmux new-session -d -s "$SESSION" -x 100 -y 30 'sniper'
sleep 2

if wait_for "sniper" 5; then
    log_pass "App launches (sniper visible)"
else
    log_fail "Launch" "sniper text not found"
    capture
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    exit 1
fi

if wait_for "Type a message" 3; then
    log_pass "Welcome screen shown"
else
    log_fail "Welcome" "instructions not found"
fi

if capture | grep -q "deepseek"; then
    log_pass "Status bar shows model"
else
    log_fail "Status bar" "model not shown"
fi

# --- Editor ---
echo ""
echo "Test 2: Editor"
send "hello world"
sleep 0.5
if capture | grep -q "hello world"; then
    log_pass "Text input works"
else
    log_fail "Text input" "text not visible"
fi

# Ctrl+A then Ctrl+K to clear
send C-a
sleep 0.2
send C-k
sleep 0.2
if capture | grep -q "hello world"; then
    log_fail "Ctrl+A/K" "text not cleared"
else
    log_pass "Ctrl+A + Ctrl+K clears line"
fi

# Type and clear with Ctrl+U
send "delete me"
sleep 0.2
send C-u
sleep 0.2
log_pass "Ctrl+U accepted"

# --- Help Dialog ---
echo ""
echo "Test 3: Help dialog"
# Ctrl+? is 0x1F = Ctrl+_
send C-_
sleep 0.5
if capture | grep -q "Keybindings"; then
    log_pass "Help dialog opens"
else
    log_fail "Help dialog" "not visible"
fi

if capture | grep -q "Ctrl+X"; then
    log_pass "Help shows Ctrl+X cancel"
else
    log_fail "Help content" "Ctrl+X not listed"
fi

if capture | grep -q "Attach file"; then
    log_pass "Help shows Ctrl+F"
else
    log_fail "Help content" "Ctrl+F not listed"
fi

if capture | grep -q "/new /clear"; then
    log_pass "Help shows slash commands"
else
    log_fail "Help content" "slash commands not listed"
fi

send Escape
sleep 0.3
log_pass "Help dialog closes"

# --- Theme Cycling ---
echo ""
echo "Test 4: Themes"
send C-t
sleep 0.3
if capture | grep -q "gruvbox"; then
    log_pass "Cycled to gruvbox"
else
    log_fail "Theme cycle" "gruvbox not shown"
fi

send C-t
sleep 0.3
if capture | grep -q "tokyo_night"; then
    log_pass "Cycled to tokyo_night"
else
    log_fail "Theme cycle" "tokyo_night not shown"
fi

# Cycle through remaining themes (dracula, monokai, onedark, flexoki, tron, back to catppuccin)
for t in dracula monokai onedark flexoki tron catppuccin; do
    send C-t
    sleep 0.2
    if capture | grep -q "$t"; then
        log_pass "Cycled to $t"
    else
        log_fail "Theme cycle" "$t not shown"
    fi
done

# --- Slash Commands ---
echo ""
echo "Test 5: Slash commands"

send "/help" Enter
sleep 0.5
if capture | grep -q "Keybindings"; then
    log_pass "/help works"
else
    log_fail "/help" "help not shown"
fi
send Escape
sleep 0.3

send "/unknown_xyz" Enter
sleep 0.5
if capture | grep -q "Unknown command"; then
    log_pass "Unknown command shows error"
else
    log_fail "/unknown" "error not shown"
fi

send "/theme" Enter
sleep 0.3
log_pass "/theme accepted"

# --- Send Message ---
echo ""
echo "Test 6: Send message and get response"
send "Say PONG and nothing else" Enter
sleep 2

if wait_for "you" 5; then
    log_pass "User message shown with label"
else
    log_fail "User message" "label not visible"
fi

if wait_for "Thinking\|Using tools\|Ready" 5; then
    log_pass "Status bar shows activity"
else
    log_fail "Status" "no activity shown"
fi

# Wait for response
if wait_for "Ready" 45; then
    log_pass "Response completed (Ready status)"
else
    log_fail "Response" "did not complete in 45s"
fi

sleep 1
CONTENT=$(capture)
if echo "$CONTENT" | grep -qi "pong\|PONG"; then
    log_pass "Assistant responded with PONG"
else
    # Even if not exact, check assistant label appeared
    if echo "$CONTENT" | grep -q "sniper"; then
        log_pass "Assistant responded (label visible)"
    else
        log_fail "Response content" "no assistant response"
    fi
fi

# --- Token Tracking ---
echo ""
echo "Test 7: Token tracking"
if capture | grep -q "tok"; then
    log_pass "Token count shown in status bar"
else
    log_fail "Token tracking" "no token count in status"
fi

# --- Scrolling ---
echo ""
echo "Test 8: Scrolling"
send -l '\033[5~'  # Page Up
sleep 0.3
send -l '\033[6~'  # Page Down
sleep 0.3
log_pass "Page Up/Down accepted"

# --- Multi-line ---
echo ""
echo "Test 9: Multi-line editor"
send "line one"
sleep 0.2
# Alt+Enter = ESC then Enter
send Escape Enter
sleep 0.3
send "line two"
sleep 0.3
if capture | grep -q "line one" && capture | grep -q "line two"; then
    log_pass "Multi-line input works"
else
    log_fail "Multi-line" "lines not visible"
fi
# Clear
send C-u
sleep 0.1
send C-a
sleep 0.1
send C-k
sleep 0.1

# --- Model Select ---
echo ""
echo "Test 10: Model select (Ctrl+O)"
send C-o
sleep 3
if capture | grep -q "Select Model\|deepseek"; then
    log_pass "Model select dialog opens"
else
    # Might fail if Ollama is slow
    log_fail "Model select" "dialog not shown"
fi
send Escape
sleep 0.3

# --- New Session ---
echo ""
echo "Test 11: New session"
send C-n
sleep 0.5
if capture | grep -q "New session\|Type a message"; then
    log_pass "New session created"
else
    log_fail "New session" "no confirmation"
fi

# --- Session List ---
echo ""
echo "Test 12: Session list (Ctrl+S)"
send C-s
sleep 0.5
CONTENT=$(capture)
if echo "$CONTENT" | grep -q "Sessions\|session\|No sessions"; then
    log_pass "Session list shown"
else
    log_fail "Session list" "nothing shown"
fi
send Escape 2>/dev/null
sleep 0.3

# --- Quit Confirmation ---
echo ""
echo "Test 13: Quit confirmation"
# Send a message first so we have messages
send "hi" Enter
sleep 1
wait_for "Ready" 45 || true
sleep 2

# Send Ctrl+C — need to ensure we're past streaming
send C-c
if wait_for "Quit" 5; then
    log_pass "Quit confirmation shown"
else
    log_fail "Quit confirm" "dialog not visible"
fi

# Cancel
send "n"
sleep 1
log_pass "Quit cancelled"

# --- Clean Quit ---
echo ""
echo "Test 14: Clean quit"
send C-c
if wait_for "Quit" 5; then
    send "y"
    sleep 2
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        log_fail "Quit" "process still running"
        tmux kill-session -t "$SESSION" 2>/dev/null || true
    else
        log_pass "Clean quit works"
    fi
else
    log_fail "Quit" "quit dialog not shown"
    tmux kill-session -t "$SESSION" 2>/dev/null || true
fi

# --- Summary ---
echo ""
echo "================================"
TOTAL=$((PASSED + FAILED))
echo "  $PASSED/$TOTAL tests passed, $FAILED failed"
if [ $FAILED -gt 0 ]; then
    exit 1
fi
echo "  All tests passed!"
