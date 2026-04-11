const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const PORT = 8085;

/**
 * Sovereign Binary Discovery
 */
function getGhostBinaryPath() {
    const platform = process.platform; 
    let exeName = platform === 'win32' ? 'ghost_sovereign.exe' : 'ghost_sovereign';

    // Structure: platforms/<arch>/<os>/web/server.js
    // Binaries are in: platforms/<arch>/<os>/bin/
    return path.join(__dirname, '..', 'bin', exeName);
}

const GHOST_EXE = getGhostBinaryPath();

console.log(`[BRIDGE] Targeted Silicon: ${GHOST_EXE}`);

if (!fs.existsSync(GHOST_EXE)) {
    console.error(`[FATAL] Sovereign binary not found at ${GHOST_EXE}. Ensure the engine is built for your platform.`);
    process.exit(1);
}

console.log("[BRIDGE] Igniting Ghost Sovereign Engine...");
const ghost = spawn(GHOST_EXE, [], { 
    cwd: path.dirname(GHOST_EXE),
    stdio: ['pipe', 'pipe', 'pipe'] 
});

let ghostBuffer = "";
ghost.stdout.on('data', (data) => {
    ghostBuffer += data.toString();
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
                await new Promise(resolve => setTimeout(resolve, 1500));
                let reply = ghostBuffer.replace(prompt, "").trim();
                if (!reply || reply.length < 2) reply = "The silicon remains silent.";
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

server.listen(PORT, () => {
    console.log(`[BRIDGE] Sovereign UI online at http://localhost:${PORT}`);
});
