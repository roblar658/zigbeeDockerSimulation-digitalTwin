# Sikre at Docker-motoren kjører
$dockerDesktopPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (-not (Get-Process "Docker Desktop" -ErrorAction SilentlyContinue)) {
    Write-Host "==> Starter Docker Desktop..." -ForegroundColor Yellow
    if (Test-Path $dockerDesktopPath) { Start-Process -FilePath $dockerDesktopPath } else { Start-Process "Docker Desktop" }
}

Write-Host "==> Verifiserer Docker..." -ForegroundColor Cyan
$ready = $false
while (-not $ready) {
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $ready = $true } else { Start-Sleep -Seconds 3 }
}
Write-Host "[OK] Docker er klar." -ForegroundColor Green

# Prosjektmappe
$workDir = "C:\Users\rober\zigbee-simulated"
if (-not (Test-Path -Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
Set-Location -Path $workDir

# Skriv oppdatert Dockerfile med termostat- og sikkerhetslogikk
@'
FROM node:20-alpine

RUN apk add --no-cache mosquitto supervisor

WORKDIR /app
RUN mkdir -p /etc/mosquitto /etc/supervisor.d /app/public

# Mosquitto MQTT & WebSockets
RUN cat <<'EOC' > /etc/mosquitto/mosquitto.conf
listener 1883 0.0.0.0
allow_anonymous true

listener 9001 0.0.0.0
protocol websockets
allow_anonymous true
EOC

# Simulator med termodynamisk kobling mellom rom og ovn
RUN cat <<'EOC' > /app/simulator.js
const mqtt = require('mqtt');
const http = require('http');
const fs = require('fs');
const path = require('path');

const client = mqtt.connect('mqtt://127.0.0.1:1883');

let baseRoomTemp = 21.0;
let roomTemp = 21.0;
let ovenState = 'OFF';
let ovenTemp = 21.0;
let maxCutoffTemp = 28.0;

client.on('connect', () => {
    client.subscribe('zigbee2mqtt/kitchen_oven/set');
    client.subscribe('zigbee2mqtt/room/settings/set');

    publishSensor();
    publishOven();

    // Termisk simuleringsløkke
    setInterval(() => {
        // 1. Ovnens interne temperatur
        if (ovenState === 'ON') {
            if (ovenTemp < 250.0) ovenTemp += 6.0;
        } else {
            if (ovenTemp > roomTemp) ovenTemp -= 3.0;
            if (ovenTemp < roomTemp) ovenTemp = roomTemp;
        }
        ovenTemp = Math.round(ovenTemp * 10) / 10;

        // Romtemperatur påvirkes av ovnens spillvarme og omgivelsene
        if (ovenState === 'ON') {
            // Ovnen varmer opp kjøkkenet
            roomTemp += 0.35 + (Math.random() - 0.5) * 0.05;
        } else {
            // Kjøler seg gradvis ned mot innstilt romtemperatur
            if (roomTemp > baseRoomTemp) {
                roomTemp -= 0.15;
            } else if (roomTemp < baseRoomTemp) {
                roomTemp += 0.15;
            }
            roomTemp += (Math.random() - 0.5) * 0.05;
        }
        roomTemp = Math.round(roomTemp * 10) / 10;

        // Sikkerhetsutkobling: Skru av ovnen hvis rommet blir for varmt
        if (ovenState === 'ON' && roomTemp >= maxCutoffTemp) {
            console.log(`[ALARM] Rommet er for varmt (${roomTemp} °C >=${maxCutoffTemp} °C)! Kutter strømmen til ovnen.`);
            ovenState = 'OFF';
            publishOven();
            client.publish('zigbee2mqtt/alarm', JSON.stringify({
                triggered: true,
                message: `Ovn slått av automatisk! Romtemperatur (${roomTemp} °C) overskred maksgrense (${maxCutoffTemp} °C).`
            }));
        }

        publishSensor();
        publishOven();
    }, 1500);
});

client.on('message', (topic, message) => {
    try {
        const payload = JSON.parse(message.toString());
        if (topic === 'zigbee2mqtt/kitchen_oven/set') {
            if (payload.state) {
                // Forhindre oppstart dersom rommet allerede er over maksgrensen
                if (payload.state.toUpperCase() === 'ON' && roomTemp >= maxCutoffTemp) {
                    console.log('[AVVIST] Kan ikke skru på ovn; rommet overskrider maksgrense.');
                    return;
                }
                ovenState = payload.state.toUpperCase();
                publishOven();
            }
        } else if (topic === 'zigbee2mqtt/room/settings/set') {
            if (payload.base_temp !== undefined) baseRoomTemp = Number(payload.base_temp);
            if (payload.max_cutoff !== undefined) maxCutoffTemp = Number(payload.max_cutoff);
            console.log(`[Innstillinger] Base: ${baseRoomTemp} °C, Cutoff:${maxCutoffTemp} °C`);
        }
    } catch (e) {}
});

function publishSensor() {
    client.publish('zigbee2mqtt/kitchen_temperature_sensor', JSON.stringify({
        temperature: roomTemp,
        base_target: baseRoomTemp,
        max_cutoff: maxCutoffTemp,
        humidity: 45.0,
        battery: 100,
        linkquality: 130
    }), { retain: true });
}

function publishOven() {
    client.publish('zigbee2mqtt/kitchen_oven', JSON.stringify({
        state: ovenState,
        current_temperature: ovenTemp,
        power: ovenState === 'ON' ? 2400 : 0,
        linkquality: 140
    }), { retain: true });
}

const server = http.createServer((req, res) => {
    const filePath = path.join(__dirname, 'public', req.url === '/' ? 'index.html' : req.url);
    if (fs.existsSync(filePath)) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        fs.createReadStream(filePath).pipe(res);
    } else {
        res.writeHead(404);
        res.end();
    }
});
server.listen(8080, '0.0.0.0');
EOC

RUN npm init -y && npm install mqtt

# Web UI med 3D-visning og temperaturkontroll
RUN cat <<'EOC' > /app/public/index.html
<!DOCTYPE html>
<html lang="no">
<head>
    <meta charset="UTF-8">
    <title>3D Smart Kitchen - Regulering & Sikkerhet</title>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/controls/OrbitControls.js"></script>
    <script src="https://unpkg.com/mqtt/dist/mqtt.min.js"></script>
    <style>
        body { margin: 0; overflow: hidden; background-color: #0b0f19; font-family: system-ui, sans-serif; color: #fff; }
        #canvas-container { width: 100vw; height: 100vh; }
        #ui {
            position: absolute;
            top: 20px;
            left: 20px;
            background: rgba(15, 23, 42, 0.88);
            backdrop-filter: blur(10px);
            padding: 1.25rem;
            border-radius: 12px;
            border: 1px solid #334155;
            box-shadow: 0 4px 20px rgba(0,0,0,0.6);
            width: 320px;
            pointer-events: auto;
        }
        h2 { margin: 0 0 10px 0; font-size: 1.15rem; color: #38bdf8; }
        h3 { margin: 12px 0 6px 0; font-size: 0.95rem; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; }
        .data-row { display: flex; justify-content: space-between; margin-bottom: 6px; font-size: 0.95rem; }
        .data-val { font-weight: bold; }
        .btn {
            width: 100%;
            margin-top: 10px;
            padding: 10px;
            border: none;
            border-radius: 6px;
            font-weight: bold;
            font-size: 1rem;
            cursor: pointer;
            transition: 0.2s;
        }
        .btn-on { background: #22c55e; color: #000; }
        .btn-off { background: #ef4444; color: #fff; }
        .slider-group { margin-bottom: 12px; }
        .slider-group label { display: flex; justify-content: space-between; font-size: 0.88rem; margin-bottom: 4px; }
        input[type=range] { width: 100%; accent-color: #38bdf8; cursor: pointer; }
        #alarm-banner {
            display: none;
            background: #991b1b;
            color: #fecaca;
            padding: 8px 10px;
            border-radius: 6px;
            font-size: 0.85rem;
            margin-top: 10px;
            border: 1px solid #ef4444;
            line-height: 1.3;
        }
    </style>
</head>
<body>
    <div id="ui">
        <h2>Kjøkken Digital Twin</h2>
        <hr style="border:0; border-top:1px solid #334155; margin-bottom:10px;">
        
        <h3>Status</h3>
        <div class="data-row">
            <span>Romtemperatur:</span>
            <span class="data-val" id="room-temp" style="color: #38bdf8;">-- °C</span>
        </div>
        <div class="data-row">
            <span>Ovnens status:</span>
            <span class="data-val" id="oven-state">OFF</span>
        </div>
        <div class="data-row">
            <span>Ovnstemperatur:</span>
            <span class="data-val" id="oven-temp">-- °C</span>
        </div>
        <div class="data-row">
            <span>Effektforbruk:</span>
            <span class="data-val" id="oven-power">0 W</span>
        </div>

        <button id="oven-btn" class="btn btn-on" onclick="toggleOven()">Skru Stekeovn PÅ</button>
        <div id="alarm-banner"></div>

        <h3>Temperaturregulering</h3>
        <div class="slider-group">
            <label>
                <span>Mål-romtemperatur:</span>
                <span id="base-temp-val">21 °C</span>
            </label>
            <input type="range" id="base-temp-slider" min="15" max="26" value="21" step="0.5" oninput="updateSettings()">
        </div>

        <div class="slider-group">
            <label>
                <span>Sikkerhetsgrense (Slå av ovn):</span>
                <span id="cutoff-temp-val" style="color: #f87171;">28 °C</span>
            </label>
            <input type="range" id="cutoff-temp-slider" min="23" max="35" value="28" step="0.5" oninput="updateSettings()">
        </div>
    </div>

    <div id="canvas-container"></div>

    <script>
        //  Three.js Scene Setup
        const container = document.getElementById('canvas-container');
        const scene = new THREE.Scene();
        scene.background = new THREE.Color(0x0f172a);

        const camera = new THREE.PerspectiveCamera(45, window.innerWidth / window.innerHeight, 0.1, 1000);
        camera.position.set(5, 4, 6);

        const renderer = new THREE.WebGLRenderer({ antialias: true });
        renderer.setSize(window.innerWidth, window.innerHeight);
        renderer.shadowMap.enabled = true;
        container.appendChild(renderer.domElement);

        const controls = new THREE.OrbitControls(camera, renderer.domElement);
        controls.enableDamping = true;
        controls.target.set(0, 1, 0);

        // Lys
        const ambientLight = new THREE.AmbientLight(0xffffff, 0.6);
        scene.add(ambientLight);

        const dirLight = new THREE.DirectionalLight(0xffffff, 0.8);
        dirLight.position.set(5, 10, 7);
        dirLight.castShadow = true;
        scene.add(dirLight);

        const ovenGlowLight = new THREE.PointLight(0xff4500, 0, 4);
        ovenGlowLight.position.set(0, 1.1, 0.2);
        scene.add(ovenGlowLight);

        // Rom og benk
        const floor = new THREE.Mesh(new THREE.PlaneGeometry(8, 8), new THREE.MeshStandardMaterial({ color: 0x1e293b, roughness: 0.8 }));
        floor.rotation.x = -Math.PI / 2;
        floor.receiveShadow = true;
        scene.add(floor);

        const backWall = new THREE.Mesh(new THREE.PlaneGeometry(8, 4), new THREE.MeshStandardMaterial({ color: 0x334155, roughness: 0.9 }));
        backWall.position.set(0, 2, -2);
        scene.add(backWall);

        const counter = new THREE.Mesh(new THREE.BoxGeometry(3, 0.9, 1.2), new THREE.MeshStandardMaterial({ color: 0x475569 }));
        counter.position.set(0, 0.45, -1.2);
        scene.add(counter);

        // Ovn
        const ovenGroup = new THREE.Group();
        const ovenBody = new THREE.Mesh(
            new THREE.BoxGeometry(1.2, 1.1, 1.1),
            new THREE.MeshStandardMaterial({ color: 0x111827, metalness: 0.8, roughness: 0.2 })
        );
        ovenGroup.add(ovenBody);

        const windowMat = new THREE.MeshStandardMaterial({ color: 0x050505, roughness: 0.1, metalness: 0.9, transparent: true, opacity: 0.9 });
        const ovenWindow = new THREE.Mesh(new THREE.PlaneGeometry(0.8, 0.6), windowMat);
        ovenWindow.position.set(0, 0, 0.56);
        ovenGroup.add(ovenWindow);

        const coilMat = new THREE.MeshBasicMaterial({ color: 0x222222 });
        const coil = new THREE.Mesh(new THREE.TorusGeometry(0.25, 0.02, 8, 24), coilMat);
        coil.rotation.x = Math.PI / 2;
        coil.position.set(0, 0.3, 0.1);
        ovenGroup.add(coil);

        ovenGroup.position.set(0, 1.1, -1.2);
        scene.add(ovenGroup);

        // Temperatursensor på veggen
        const sensorMat = new THREE.MeshStandardMaterial({ color: 0x38bdf8, roughness: 0.3, emissive: 0x0ea5e9, emissiveIntensity: 0.2 });
        const sensor = new THREE.Mesh(new THREE.CylinderGeometry(0.12, 0.12, 0.05, 32), sensorMat);
        sensor.rotation.x = Math.PI / 2;
        sensor.position.set(-1.8, 2.3, -1.97);
        scene.add(sensor);

        //  MQTT-tilkobling
        let currentOvenState = 'OFF';
        const client = mqtt.connect('ws://' + window.location.hostname + ':9001');

        client.on('connect', () => {
            client.subscribe('zigbee2mqtt/#');
        });

        client.on('message', (topic, message) => {
            const data = JSON.parse(message.toString());

            if (topic === 'zigbee2mqtt/kitchen_temperature_sensor') {
                const temp = data.temperature.toFixed(1);
                document.getElementById('room-temp').innerText = temp + ' °C';

                // Sensorfarge dynamisk (blå -> gul -> rød)
                const t = Math.max(16, Math.min(32, data.temperature));
                const ratio = (t - 16) / 16;
                sensorMat.color.setRGB(ratio, 0.6 * (1 - Math.abs(ratio - 0.5) * 2), 1 - ratio);
                sensorMat.emissive.setRGB(ratio * 0.4, 0.1, (1 - ratio) * 0.4);

                // Skjul alarm når temperaturen synker under cutoff
                const cutoff = parseFloat(document.getElementById('cutoff-temp-slider').value);
                if (data.temperature < cutoff) {
                    document.getElementById('alarm-banner').style.display = 'none';
                }
            }

            if (topic === 'zigbee2mqtt/kitchen_oven') {
                currentOvenState = data.state;
                document.getElementById('oven-state').innerText = data.state;
                document.getElementById('oven-temp').innerText = data.current_temperature.toFixed(1) + ' °C';
                document.getElementById('oven-power').innerText = data.power + ' W';

                const btn = document.getElementById('oven-btn');
                if (data.state === 'ON') {
                    btn.innerText = 'Skru Stekeovn AV';
                    btn.className = 'btn btn-off';

                    ovenGlowLight.intensity = Math.min(3, 0.5 + (data.current_temperature / 90));
                    windowMat.emissive.setHex(0xd97706);
                    windowMat.emissiveIntensity = 0.6;
                    coilMat.color.setHex(0xff3300);
                } else {
                    btn.innerText = 'Skru Stekeovn PÅ';
                    btn.className = 'btn btn-on';

                    ovenGlowLight.intensity = 0;
                    windowMat.emissive.setHex(0x000000);
                    coilMat.color.setHex(0x222222);
                }
            }

            if (topic === 'zigbee2mqtt/alarm') {
                const banner = document.getElementById('alarm-banner');
                banner.innerText = data.message;
                banner.style.display = 'block';
            }
        });

        window.toggleOven = function() {
            const next = currentOvenState === 'ON' ? 'OFF' : 'ON';
            client.publish('zigbee2mqtt/kitchen_oven/set', JSON.stringify({ state: next }));
        };

        window.updateSettings = function() {
            const base = document.getElementById('base-temp-slider').value;
            const cutoff = document.getElementById('cutoff-temp-slider').value;
            document.getElementById('base-temp-val').innerText = base + ' °C';
            document.getElementById('cutoff-temp-val').innerText = cutoff + ' °C';

            client.publish('zigbee2mqtt/room/settings/set', JSON.stringify({
                base_temp: parseFloat(base),
                max_cutoff: parseFloat(cutoff)
            }));
        };

        window.addEventListener('resize', () => {
            camera.aspect = window.innerWidth / window.innerHeight;
            camera.updateProjectionMatrix();
            renderer.setSize(window.innerWidth, window.innerHeight);
        });

        function animate() {
            requestAnimationFrame(animate);
            controls.update();
            renderer.render(scene, camera);
        }
        animate();
    </script>
</body>
</html>
EOC

# Supervisor
RUN cat <<'EOC' > /etc/supervisor.d/services.ini
[supervisord]
nodaemon=true
user=root

[program:mosquitto]
command=/usr/sbin/mosquitto -c /etc/mosquitto/mosquitto.conf
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:simulator]
directory=/app
command=node simulator.js
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
depends_on=mosquitto
EOC

EXPOSE 1883 9001 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor.d/services.ini"]
'@ | Out-File -FilePath "$workDir\Dockerfile" -Encoding utf8

# 4. Bygg og restart container
Write-Host "==> Bygger oppdatert bilde med termostat og sikkerhetskutt..." -ForegroundColor Cyan
docker build -t zigbee-simulated .

docker rm -f zigbee_sim 2>$null

Write-Host "==> Starter container..." -ForegroundColor Cyan
docker run -d `
  --name zigbee_sim `
  --restart unless-stopped `
  -p 1883:1883 `
  -p 9001:9001 `
  -p 8080:8080 `
  zigbee-simulated

Write-Host "`n==> Ferdig! Åpne http://localhost:8080 i nettleseren." -ForegroundColor Green
