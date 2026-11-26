# Runs on the Linux test box (tools/matrix/run_matrix.sh uploads and starts it): linrun.sh 46|48|50
# builds the IDE and the plugin from /root/mcp-code (the tree git_serve sent), starts the IDE with the test
# hooks, runs the full suite (hooks off in the test program: the dialog-hook suite cannot run on Linux),
# then the progress suite alone with hooks on.  Paths are those of the box described in the matrix README.
VER=$1
cd /root; rm -f jx$VER.done tx$VER.txt; export DISPLAY=:1
exec > /root/jx$VER.log 2>&1
pkill -x lazarus; pkill -f mcpserver_tests; sleep 3
pgrep -x twm >/dev/null || (setsid nohup twm </dev/null >/root/twm.log 2>&1 &)
if [ "$VER" = 46 ]; then
  LD=/usr/share/lazarus/4.6.0; PCP=/root/.lazarus; TREE=/root/lazarus-mcp-assistant; PROJ=/root/guiproj/guiproj.lpi
  cd $TREE; git checkout -f -q -- .
  git fetch -q /root/mcp-code refs/remotes/mcp/snapshot || exit 1
  git checkout -f -q -B release/1.9.0 FETCH_HEAD
  L="lazbuild --lazarusdir=$LD --pcp=$PCP"
  $L src/lazmcpassistant.lpk 2>&1 | grep -E "Error|Fatal" | head
else
  if [ "$VER" = 48 ]; then LD=/root/laz48; PCP=/root/pcp48; TREE=/root/lazmcp-48; WS=gtk2; else LD=/root/laz50; PCP=/root/pcp50; TREE=/root/lazmcp-50; WS=gtk3; fi
  PROJ=$TREE/tests/windowee/mcpwindowee.lpi
  cd $TREE; git config user.email t@t; git config user.name t
  git ls-files -z | xargs -0 rm -f
  git -C /root/mcp-code archive HEAD | tar -x -C $TREE
  git add -A >/dev/null 2>&1; git commit -q -m snapshot
  L="$LD/lazbuild --pcp=$PCP --lazarusdir=$LD --widgetset=$WS"
  export MCP_OPTIONS_FILE=$PCP/mcpassistantoptions.xml
fi
echo "tree $(git -C /root/mcp-code rev-parse --short HEAD)"
$L --build-ide= 2>&1 | tail -2; echo "buildide done"
$L tests/mcpserver_tests.lpi 2>&1 | grep -E "Error|Fatal|Linking" | head -3
if [ "$VER" = 46 ]; then (MCP_TEST_HOOKS=1 setsid nohup $LD/lazarus --pcp=$PCP $PROJ </dev/null > /root/ide$VER.log 2>&1 &)
else (MCP_TEST_HOOKS=1 setsid nohup $LD/lazarus --pcp=$PCP --no-splash-screen $PROJ </dev/null > /root/ide$VER.log 2>&1 &); fi
for i in $(seq 1 30); do c=$(timeout 5 curl -s -m 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:56180/mcp); [ "$c" != 000 ] && break; sleep 5; done
echo "port http $c after $i"
sleep 20
cd $TREE
export MCP_DEBUG_TESTS=1
timeout 3000 tests/mcpserver_tests --all --format=plain > /root/tx$VER.txt 2>&1; F=$?
MCP_TEST_HOOKS=1 timeout 600 tests/mcpserver_tests --suite=TTestProgress --format=plain > /root/tp$VER.txt 2>&1; P=$?
echo "full=$F progress=$P" > /root/jx$VER.done
