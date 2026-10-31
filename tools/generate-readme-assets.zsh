#!/usr/bin/env zsh
# ---------------------------------------------------------------------------
# tools/generate-readme-assets.zsh — regenerate the README images.
#
# Runs the REAL ccsend, unmodified, against a REAL host: a throwaway Debian
# container (hostname devbox, user alice) with sshd, python3 and tmux, two fake
# Claude Code sessions in tmux (copies of python3 named `claude`, the same
# trick the injection tests use) and one SSH login shell. Nothing about your
# own setup takes part:
#
#   * CCSEND_HOME points ccsend at a sandbox home: its own config, log, SSH
#     control sockets. Your ~/.config/ccsend is never read.
#   * the host is reached on a localhost port with a sandbox key and
#     known_hosts file, through ssh_options; copy_path is off, so your
#     clipboard is never touched.
#   * the windows are rendered with the app's own snapshot aid
#     (CCSEND_SNAPSHOT + CCSEND_SNAPSHOT_FRAME): invisible, never focused, no
#     Screen Recording permission needed.
#
# Window screenshots are PNGs. Terminal use is drawn as SVG, the way the
# sibling tools (ccfind, rtmux, claude-profile …) draw theirs: the text is the
# genuine output of the run, laid out on a terminal grid. Only the window
# chrome and fzf's own furniture are drawn; a stub `fzf` records exactly the
# rows ccsend hands the picker and chooses the first one (the guess).
#
# demo.svg is the same material on a CSS keyframe timeline: an SVG in an <img>
# renders with scripting off but declarative animation on, which is what makes
# it work on GitHub. prefers-reduced-motion freezes it on its final frame.
#
# Usage:  zsh tools/generate-readme-assets.zsh
#           → assets/{send,import}-<hash>.png, assets/{demo,picker}-<hash>.svg,
#             older ones deleted, README references rewritten (the hash busts
#             GitHub's image cache). Commit them with the README.
#         zsh tools/generate-readme-assets.zsh OUTDIR
#           → fixed names in OUTDIR, README untouched.
#
# Needs: Docker, and a built app (make). Rerun whenever the window, the CLI
# output or the picker changes.
# ---------------------------------------------------------------------------
emulate -L zsh
setopt extended_glob pipe_fail

here=${0:a:h}
root=${here:h}
ccsend="$root/client/build/ccsend.app/Contents/MacOS/ccsend"
[[ -x $ccsend ]] || { print -u2 "generate-readme-assets: build first (make)"; exit 1 }
docker info >/dev/null 2>&1 || { print -u2 "generate-readme-assets: Docker is not running"; exit 1 }

# Short path on purpose: SSH control sockets live under it (104-byte limit).
tmp=$(mktemp -d /tmp/ccsr.XXXXXX)
ctr="ccsend-readme-$$"
cleanup() {
  docker rm -f "$ctr" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# ---- the host ----------------------------------------------------------------
print -u2 "building the demo host image…"
docker build -q -t ccsend-readme-host - >/dev/null <<'DOCKERFILE' || exit 1
FROM debian:bookworm-slim
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      openssh-server openssh-client python3 tmux procps >/dev/null && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash alice && mkdir -p /run/sshd /home/alice/.ssh \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAllowUsers alice\n' \
      > /etc/ssh/sshd_config.d/demo.conf
CMD ["/usr/sbin/sshd", "-D", "-e"]
DOCKERFILE

docker run -d --name "$ctr" --hostname devbox -p 127.0.0.1::22 ccsend-readme-host >/dev/null || exit 1
port=$(docker port "$ctr" 22 | head -1); port=${port##*:}

H="$tmp/home"
mkdir -p "$H/.config/ccsend" "$H/Downloads" "$H/Desktop" "$H/Library/Logs" "$tmp/ssh" "$tmp/bin"
ssh-keygen -q -t ed25519 -N '' -C demo -f "$tmp/ssh/id"
docker cp "$tmp/ssh/id.pub" "$ctr:/home/alice/.ssh/authorized_keys" >/dev/null
docker exec "$ctr" sh -c 'chown -R alice:alice /home/alice/.ssh && chmod 700 /home/alice/.ssh && chmod 600 /home/alice/.ssh/authorized_keys'

integer tries
for (( tries = 0; tries < 50; tries++ )); do
  ssh-keyscan -p "$port" -t ed25519 127.0.0.1 2>/dev/null | sed "s/^\[127.0.0.1\]:$port/devbox/" > "$tmp/ssh/known_hosts"
  [[ -s $tmp/ssh/known_hosts ]] && break
  sleep 0.2
done
[[ -s $tmp/ssh/known_hosts ]] || { print -u2 "generate-readme-assets: sshd did not come up"; exit 1 }

# The host's contents and sessions, created as alice. The fake claude prints a
# "> " prompt so the pane shows what injection typed after it.
cat > "$tmp/seed.sh" <<'SEED'
set -e
cd ~
mkdir -p .local/bin code/floke/src code/floke/out code/api-gateway code/blog/posts notes inbox
cp /usr/bin/python3 .local/bin/claude
touch code/floke/README.md code/floke/Cargo.toml code/floke/src/main.rs code/api-gateway/main.go \
      code/blog/posts/hello.md notes/todo.md
head -c 2000000 /dev/urandom > code/floke/out/report.pdf
head -c 412000 /dev/urandom > code/floke/out/chart.png
head -c 23000 /dev/urandom > code/floke/out/results.csv
mkdir -p code/floke/out/frames && head -c 96000 /dev/urandom > code/floke/out/frames/0001.png
ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/self && cat ~/.ssh/self.pub >> ~/.ssh/authorized_keys
FAKE='import sys, time; sys.stdout.write("> "); sys.stdout.flush(); time.sleep(10**9)'
tmux new -d -s api -c ~/code/api-gateway ~/.local/bin/claude -c "$FAKE"
sleep 1
# An SSH login shell (what "shell" sessions are), parked in ~/code/blog.
setsid -f sh -c 'sleep 1000000 | ssh -tt -o StrictHostKeyChecking=accept-new -i ~/.ssh/self localhost "cd ~/code/blog && exec bash -i" >/dev/null 2>&1'
sleep 1
tmux new -d -s floke -c ~/code/floke ~/.local/bin/claude -c "$FAKE"
sleep 1
SEED
docker cp "$tmp/seed.sh" "$ctr:/tmp/seed.sh" >/dev/null
docker exec -u alice "$ctr" sh /tmp/seed.sh || exit 1

# ---- the Mac side --------------------------------------------------------------
cat > "$H/.config/ccsend/config.toml" <<TOML
[ui]
guess_destination = true
copy_path = false

[hosts.devbox]
ssh = "127.0.0.1"
user = "alice"
ssh_options = ["Port=$port", "HostKeyAlias=devbox", "UserKnownHostsFile=$tmp/ssh/known_hosts",
               "IdentityFile=$tmp/ssh/id", "IdentitiesOnly=yes"]
default_location = "~/inbox"
inject = "type"
import = true
import_start = "~/code/floke/out"
TOML
chmod 600 "$H/.config/ccsend/config.toml"
# Round sizes, so the byte counts read the same in every locale.
head -c 3000000 /dev/urandom > "$H/Downloads/Floke-6.zip"

export CCSEND_HOME="$H"
"$ccsend" check >/dev/null || { print -u2 "generate-readme-assets: ccsend check failed"; "$ccsend" check; exit 1 }

# ---- window screenshots ----------------------------------------------------------
# snap <name> <ccsend args…>: render one window after the host has answered.
snap() {
  local name=$1; shift
  local out="$tmp/shot-$name"
  CCSEND_SNAPSHOT="$out" CCSEND_SNAPSHOT_AT=4 CCSEND_SNAPSHOT_FRAME=1 "$ccsend" "$@" >/dev/null 2>&1 &
  local pid=$!
  # The app quits by itself after its last snapshot; kill it only if it hangs.
  integer t=0
  while kill -0 $pid 2>/dev/null && (( t++ < 100 )); do sleep 0.2; done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  [[ -s "$out-0.png" ]] || { print -u2 "generate-readme-assets: no snapshot for $name"; exit 1 }
}
print -u2 "rendering the windows…"
snap send ui --host devbox -- "$H/Downloads/Floke-6.zip"
snap import ui-import --host devbox --to "$H/Downloads"

# ---- terminal runs -----------------------------------------------------------------
# A stub fzf, first on PATH: records its argv and the rows, chooses the first.
cat > "$tmp/bin/fzf" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$FZF_ARGS"
tee "$FZF_CAPTURE" | head -1
STUB
# The picker needs a terminal on stdin and stderr: give the run a pty.
cat > "$tmp/bin/inpty" <<'PTY'
#!/usr/bin/python3 -I
import os, subprocess, sys
m, s = os.openpty()
p = subprocess.Popen(sys.argv[1:], stdin=s, stdout=s, stderr=s, close_fds=True)
os.close(s)
out = b""
while True:
    try:
        b = os.read(m, 65536)
    except OSError:
        break
    if not b:
        break
    out += b
p.wait()
sys.stdout.write(out.decode("utf-8", "replace").replace("\r\n", "\n"))
sys.exit(p.returncode)
PTY
chmod +x "$tmp/bin/fzf" "$tmp/bin/inpty"

print -u2 "running the CLI…"
send_out=$(FZF_ARGS="$tmp/fzf-args" FZF_CAPTURE="$tmp/fzf-rows" PATH="$tmp/bin:$PATH" \
           "$tmp/bin/inpty" "$ccsend" send devbox "$H/Downloads/Floke-6.zip") || { print -u2 "$send_out"; exit 1 }
sleep 0.5
pane=$(docker exec -u alice "$ctr" tmux capture-pane -p -t floke | sed '/^$/d' | head -1)

typeset -a rows fargs
rows=("${(@f)$(<"$tmp/fzf-rows")}"); rows=(${rows:#})
rows=("${(@)rows#*$'\t'}")               # --with-nth=2..: fzf hides the index
fargs=("${(@f)$(<"$tmp/fzf-args")}")
prompt='' header=''
for a in "${fargs[@]}"; do
  [[ $a == --prompt=* ]] && prompt=${a#--prompt=}
  [[ $a == --header=* ]] && header=${a#--header=}
done
[[ -n $send_out && ${#rows} -gt 0 && -n $prompt && -n $pane ]] || {
  print -u2 "generate-readme-assets: the runs produced no output — aborting"; exit 1
}

# ---------------------------------------------------------------------------
# SVG (the grid and chrome follow ccfind's tools/generate-readme-svg.zsh)
# ---------------------------------------------------------------------------
BG='#1e1e2e'  BAR='#181825'  FG='#cdd6f4'  DIMC='#9399b2'
DOT1='#f38ba8' DOT2='#f9e2af' DOT3='#a6e3a1'
ACC='#89dceb'  PTR='#f38ba8'  INFO='#f9e2af'  RULE='#45475a'  GUT='#313244'  HL='#313244'
OK='#a6e3a1'   PATHC='#89b4fa'
FONT="'Cascadia Code','Fira Code',SFMono-Regular,Consolas,Menlo,monospace"
integer FS=13 LH=20 TH=30 PX=20 PY=14 SLACK=24 MINCOLS=60

typeset -a XCOL
local -F cw=7.85
integer k; local v
for (( k = 0; k <= 300; k++ )); do printf -v v '%.2f' $(( PX + k * cw )); XCOL[k+1]=$v; done
xrun() { print -rn -- "${(j: :)XCOL[$1+1,$1+$2]}" }
xat()  { print -rn -- "$XCOL[$1+1]" }
xesc() { local s=$1; s=${s//\&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; print -rn -- "$s" }

# emit_lines <array-name> <W>: one terminal's lines. Entry format TYPE|text:
#   b blank   t typed command   o output   s output, success   u output, a remote path
#   c dim     x prompt + block cursor after the text
#   q fzf prompt + cursor   i fzf counter + rule   h fzf header   n row   p current row
emit_lines() {
  local -a _l=("${(@P)1}")
  integer W=$2 i=0 y
  local entry typ body T fill
  for entry in "${_l[@]}"; do
    typ=${entry%%\|*}; body=${entry#*|}
    y=$(( TH + PY + i * LH + FS ))
    T="  <text y=\"$y\" font-family=\"$FONT\" font-size=\"$FS\" xml:space=\"preserve\""
    case $typ in
      b) ;;
      t|o|s|u|c)
        case $typ in s) fill=$OK ;; u) fill=$PATHC ;; c) fill=$DIMC ;; *) fill=$FG ;; esac
        print -r -- "$T fill=\"$fill\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>" ;;
      x|q)
        print -r -- "  <rect x=\"$(xat ${#body})\" y=\"$(( y - FS + 1 ))\" width=\"8\" height=\"$(( FS + 3 ))\" fill=\"$FG\" opacity=\"0.75\"/>"
        [[ $typ == q ]] && fill=$ACC || fill=$FG
        print -r -- "$T fill=\"$fill\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>" ;;
      i)
        integer rx=$(( PX + (${#body} + 3) * cw ))
        print -r -- "  <rect x=\"$rx\" y=\"$(( y - FS / 2 + 1 ))\" width=\"$(( W - rx - PX ))\" height=\"1\" fill=\"$RULE\"/>"
        print -r -- "$T fill=\"$INFO\"><tspan x=\"$(xrun 2 ${#body})\">$(xesc "$body")</tspan></text>" ;;
      h) print -r -- "$T fill=\"$DIMC\"><tspan x=\"$(xrun 2 ${#body})\">$(xesc "$body")</tspan></text>" ;;
      n|p)
        if [[ $typ == p ]]; then
          print -r -- "  <rect x=\"0\" y=\"$(( y - FS - 3 ))\" width=\"$W\" height=\"$LH\" fill=\"$HL\"/>"
          print -r -- "  <rect x=\"$(xat 0)\" y=\"$(( y - FS - 3 ))\" width=\"3\" height=\"$LH\" fill=\"$PTR\"/>"
        else
          print -r -- "  <rect x=\"$(xat 0)\" y=\"$(( y - FS - 3 ))\" width=\"3\" height=\"$LH\" fill=\"$GUT\"/>"
        fi
        print -r -- "$T fill=\"$FG\"><tspan x=\"$(xrun 2 ${#body})\">$(xesc "$body")</tspan></text>" ;;
    esac
    (( i++ ))
  done
}

chrome() {
  integer W=$1 H=$2
  print -r -- "  <rect width=\"$W\" height=\"$H\" rx=\"10\" fill=\"$BG\"/>"
  print -r -- "  <rect width=\"$W\" height=\"$TH\" rx=\"10\" fill=\"$BAR\"/>"
  print -r -- "  <rect y=\"$(( TH - 6 ))\" width=\"$W\" height=\"6\" fill=\"$BAR\"/>"
  print -r -- "  <circle cx=\"18\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT1\"/><circle cx=\"36\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT2\"/><circle cx=\"54\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT3\"/>"
  print -r -- "  <text x=\"$(( W / 2 ))\" y=\"$(( TH / 2 + 5 ))\" text-anchor=\"middle\" font-family=\"$FONT\" font-size=\"12\" fill=\"$DIMC\">$3</text>"
}
svg_open()  { print -r -- "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$1\" height=\"$2\" viewBox=\"0 0 $1 $2\" role=\"img\" aria-label=\"$(xesc "$3")\">" }
svg_close() { print -r -- "</svg>" }

# cols_of <array-name>…: the widest line across these frames.
cols_of() {
  integer cols=$MINCOLS n
  local arr e
  for arr in "$@"; do
    local -a _l=("${(@P)arr}")
    for e in "${_l[@]}"; do
      n=${#${e#*|}}; [[ ${e%%\|*} == (p|n|h|i) ]] && (( n += 2 ))
      (( n > cols )) && cols=$n
    done
  done
  print -rn -- $cols
}
lines_of() {
  integer n=0; local arr
  for arr in "$@"; do local -a _l=("${(@P)arr}"); (( ${#_l} > n )) && n=${#_l}; done
  print -rn -- $n
}
canvas_w() { print -rn -- $(( PX * 2 + $1 * cw + SLACK )) }
canvas_h() { print -rn -- $(( TH + PY + $1 * LH + PY )) }

# ---- compose -----------------------------------------------------------------------
# The command as typed: the sandbox home shown as the ~ it stands for.
CMD_SEND='ccsend send devbox ~/Downloads/Floke-6.zip'
P='$ '

# output lines → entries; the sent path and the success lines get colour.
typeset -a send_lines
for ln in "${(@f)send_out}"; do
  case $ln in
    sent\ to*|typed\ into*) send_lines+=("s|$ln") ;;
    /*)                     send_lines+=("u|$ln") ;;
    *)                      send_lines+=("o|$ln") ;;
  esac
done
plan_line=${send_lines[1]}; send_result=("${(@)send_lines[2,-1]}")

# fzf with --reverse --height: prompt, counter, header, rows, under the command.
fzf_frame() {   # <out-array> <current-row>
  local -a out=("q|$prompt" "i|${#rows}/${#rows}" "h|$header")
  integer j
  for (( j = 1; j <= ${#rows}; j++ )); do
    (( j == $2 )) && out+=("p|${rows[j]}") || out+=("n|${rows[j]}")
  done
  set -A $1 "${out[@]}"
}

typeset -a picker
fzf_frame picker 1
picker=("t|$P$CMD_SEND" "$plan_line" "${picker[@]}")

# The animation: the command types itself, the plan, the picker, Enter, the
# result, and then the Claude pane on devbox with the path typed into it.
typeset -a FR FR_KEY FR_DUR
integer ci
for (( ci = 0; ci <= ${#CMD_SEND}; ci++ )); do
  set -A "type$ci" "x|$P${CMD_SEND[1,ci]}"
  FR+=("type$ci"); FR_KEY+=(''); FR_DUR+=(45)
done
FR_DUR[-1]=500
typeset -a a1 a2 a3 a4
a1=("t|$P$CMD_SEND" "$plan_line" "c|…")
a2=("${picker[@]}")
a3=("t|$P$CMD_SEND" "$plan_line" "${send_result[@]}" "x|$P")
a4=("${a3[@]}" 'b|' "c|── meanwhile on devbox, tmux session floke: Claude's prompt ──" "x|$pane ")
FR+=(a1 a2 a3 a4); FR_KEY+=('⏎' '' '⏎' ''); FR_DUR+=(500 2600 1800 5200)

keycap() {
  integer x=$(( $1 - 58 )) y=$(( TH + 10 ))
  print -r -- "  <rect x=\"$x\" y=\"$y\" width=\"38\" height=\"26\" rx=\"6\" fill=\"$HL\" stroke=\"$RULE\"/>"
  print -r -- "  <text x=\"$(( x + 19 ))\" y=\"$(( y + 18 ))\" text-anchor=\"middle\" font-family=\"$FONT\" font-size=\"14\" fill=\"$FG\">$2</text>"
}

out_svg() {   # <file> <array> <aria>
  integer W=$(canvas_w $(cols_of $2)) H=$(canvas_h $(lines_of $2))
  { svg_open $W $H "$3"; chrome $W $H 'alice@mac — zsh'; emit_lines $2 $W; svg_close } > "$1"
}

anim_svg() {  # <file> <aria>
  integer W=$(canvas_w $(cols_of "${FR[@]}")) H=$(canvas_h $(lines_of "${FR[@]}"))
  integer total=0 n at=0 j
  for n in "${FR_DUR[@]}"; do (( total += n )); done
  local -F p0 p1
  {
    svg_open $W $H "$2"
    # One <g> per frame, each shown for its slice of the loop. step-end makes
    # every switch a hard cut, as a terminal redraw is (see ccfind's generator
    # for why two stops at one percentage do not).
    print -r -- "  <style>"
    print -r -- "    .fr{opacity:0}"
    for (( j = 1; j <= ${#FR}; j++ )); do
      p0=$(( at * 100.0 / total )); (( at += FR_DUR[j] )); p1=$(( at * 100.0 / total ))
      print -r -- "    #fr$j{animation:k$j ${total}ms step-end infinite}"
      if (( j == 1 )); then printf '    @keyframes k%d{0%%{opacity:1}%.3f%%{opacity:0}}\n' $j $p1
      elif (( j == ${#FR} )); then printf '    @keyframes k%d{0%%{opacity:0}%.3f%%{opacity:1}}\n' $j $p0
      else printf '    @keyframes k%d{0%%{opacity:0}%.3f%%{opacity:1}%.3f%%{opacity:0}}\n' $j $p0 $p1; fi
    done
    print -r -- "    @media (prefers-reduced-motion:reduce){.fr{animation:none!important;opacity:0}#fr${#FR}{opacity:1}}"
    print -r -- "  </style>"
    chrome $W $H 'alice@mac — zsh'
    for (( j = 1; j <= ${#FR}; j++ )); do
      # opacity="0" on all but the last: a renderer without CSS shows the end state.
      print -r -- "  <g id=\"fr$j\" class=\"fr\"$( (( j < ${#FR} )) && print -n ' opacity="0"')>"
      emit_lines ${FR[j]} $W
      [[ -n ${FR_KEY[j]} ]] && keycap $W "${FR_KEY[j]}"
      print -r -- "  </g>"
    done
    svg_close
  } > "$1"
}

DEMO_ARIA='ccsend at the terminal: sending Floke-6.zip to devbox, the picker listing the Claude session in ~/code/floke first because it matches the file name, then the file arriving there and its path typed into that Claude prompt'
PICKER_ARIA='the ccsend destination picker: the guessed Claude session first, then an SSH shell, another Claude session, the default location and a typed path'

write_all() {   # <dir> <suffix>
  anim_svg "$1/demo$2.svg" "$DEMO_ARIA"
  out_svg  "$1/picker$2.svg"   picker         "$PICKER_ARIA"
  cp "$tmp/shot-send-0.png"   "$1/send$2.png"
  cp "$tmp/shot-import-0.png" "$1/import$2.png"
}

if [[ -n ${1:-} ]]; then
  mkdir -p "$1"; write_all "$1" ''
  print "wrote $1/{demo,picker}.svg and $1/{send,import}.png"
else
  mkdir -p "$root/assets"
  rm -f "$root"/assets/(demo|picker|send|import)-*.(svg|png)(N)
  hash=$(xxd -l3 -p /dev/urandom)
  write_all "$root/assets" "-$hash"
  sed -i.bak -E "s#assets/(demo|picker|send|import)-[0-9a-f]+\.(svg|png)#assets/\1-$hash.\2#g" "$root/README.md" \
    && rm -f "$root/README.md.bak"
  print "wrote assets/*-$hash.{svg,png} and updated README.md"
fi
