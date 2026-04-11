const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

let PORT = 8085;

/**
 * Sovereign Binary & Environment Discovery
 * Detects architecture and connects to the correct platform silo.
 */
function getGhostContext() {
    const platform = process.platform;
    const arch = process.arch === 'x64' ? 'x86_64' : process.arch;
    const exeName = platform === 'win32' ? 'ghost_pulse.exe' : 'ghost_pulse';
    
    // The web server lives in platforms/<os>/web/
    // The binary lives in platforms/<os>/<arch>/bin/
    const siloRoot = path.join(__dirname, '..', arch);
    const binPath = path.join(siloRoot, 'bin', exeName);

    if (fs.existsSync(binPath)) {
        return { bin: binPath, cwd: siloRoot };
    }

    // Fallback for development if silos aren't populated
    const fallbackRoot = path.join(__dirname, '..', '..', '..');
    const fallbackBin = path.join(fallbackRoot, 'zig-out', 'bin', exeName);
    
    if (fs.existsSync(fallbackBin)) {
        return { bin: fallbackBin, cwd: fallbackRoot };
    }
    
    return { bin: binPath, cwd: siloRoot }; 
}

const { bin: GHOST_EXE, cwd: RUNTIME_CWD } = getGhostContext();

if (!fs.existsSync(GHOST_EXE)) {
    console.error(`[FATAL] Sovereign binary not found at ${GHOST_EXE}. Build the engine first.`);
    process.exit(1);
}

console.log(`[BRIDGE] Connecting to Silicon: ${GHOST_EXE}`);
console.log(`[BRIDGE] Runtime Context: ${RUNTIME_CWD}`);
console.log("[BRIDGE] Platform Isolation: Enabled (Weights localized to platform silo)");

const ghost = spawn(GHOST_EXE, [], { 
    cwd: RUNTIME_CWD,
    stdio: ['pipe', 'pipe', 'pipe'] 
});

let ghostBuffer = "";
ghost.stdout.on('data', (data) => {
    ghostBuffer += data.toString();
    process.stdout.write(`[GHOST] ${data}`);
});

ghost.stderr.on('data', (data) => {
    console.error(`[GHOST_ERR] ${data}`);
});

const server = http.createServer((req, res) => {
    if (req.url === '/' && req.method === 'GET') {
        fs.readFile(path.join(__dirname, 'index.html'), (err, data) => {
            if (err) {
                res.writeHead(500);
                res.end("Internal Interface Error");
                return;
            }
            res.writeHead(200, { 'Content-Type': 'text/html' });
            res.end(data);
        });
    } else if (req.url === '/chat' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', async () => {
            try {
                const { prompt } = JSON.parse(body);
                ghostBuffer = "";
                ghost.stdin.write(prompt + "\n");
                await new Promise(resolve => setTimeout(resolve, 2000));
                let reply = ghostBuffer.replace(prompt, "").trim();
                if (!reply || reply.length < 2) reply = "Pulse detected, but meaning remained below threshold.";
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ reply }));
            } catch (e) {
                res.writeHead(400);
                res.end(JSON.stringify({ error: "Invalid Request" }));
            }
        });
    } else {
        res.writeHead(404);
        res.end();
    }
});

function startServer(portToTry) {
    server.listen(portToTry, () => {
        console.log(`[BRIDGE] Sovereign UI online at http://localhost:${portToTry}`);
        console.log(`LAUNCH_URL: http://localhost:${portToTry}`);
    }).on('error', (err) => {
        if (err.code === 'EADDRINUSE') {
            console.log(`[BRIDGE] Port ${portToTry} in use, searching...`);
            startServer(portToTry + 1);
        } else {
            console.error(err);
        }
    });
}

startServer(PORT);
