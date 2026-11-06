import Foundation

/// A small page for comparing clips by ear, written next to them. It never plays anything until
/// PLAY is pressed. All versions run together and only one is heard, so a switch stays in time.
public enum ListenPage {
    public static func write(to folder: URL, tracks: [String], tempos: [Int]) throws {
        let list = try JSONSerialization.data(withJSONObject: ["tracks": tracks, "tempos": tempos])
        let page = template.replacingOccurrences(of: "__CLIPS__", with: String(decoding: list, as: UTF8.self))
        try page.write(to: folder.appendingPathComponent("listen.html"), atomically: true, encoding: .utf8)
    }

    private static let template = #"""
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Stretcher A/B</title>
    <style>
    :root { --bg:#111214; --panel:#1b1d20; --line:#34373b; --text:#f2f4f3; --dim:#a6abaf; --blue:#276fff; --green:#49ba60; --yellow:#dbe22d; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:18px/1.4 "Avenir Next","Helvetica Neue",sans-serif; }
    main { max-width:760px; margin:0 auto; padding:24px 16px 48px; }
    h1 { font-size:26px; margin:0 0 4px; font-weight:600; }
    p { color:var(--dim); margin:0 0 20px; }
    .row { display:flex; flex-wrap:wrap; gap:10px; margin:0 0 16px; align-items:center; }
    label { color:var(--dim); font-size:16px; width:100%; margin-bottom:-4px; }
    button { font:inherit; font-weight:600; color:var(--text); background:var(--panel); border:1px solid var(--line); border-radius:4px; padding:10px 16px; min-height:44px; cursor:pointer; }
    button.on { background:var(--blue); border-color:var(--blue); color:#000; }
    .versions button { flex:1 1 30%; font-size:30px; padding:22px 8px; }
    .versions small { display:block; font-size:14px; font-weight:500; min-height:20px; }
    #play { background:var(--green); border-color:var(--green); color:#000; min-width:120px; }
    #best.on { background:var(--yellow); border-color:var(--yellow); color:#000; }
    table { width:100%; border-collapse:collapse; font-size:16px; margin-top:12px; }
    td,th { border-bottom:1px solid var(--line); padding:6px 4px; text-align:left; }
    th { color:var(--dim); font-weight:500; }
    #why { color:var(--yellow); min-height:26px; }
    </style></head><body><main>
    <h1>Stretcher A/B</h1>
    <p>Three versions of the same passage at the same tempo, level matched. Keys 1, 2, 3 switch while it plays, space plays and stops. The names stay hidden until you press REVEAL.</p>
    <div class="row" id="tracks"><label>Track</label></div>
    <div class="row" id="tempos"><label>Tempo, % of the track's speed</label></div>
    <div class="row versions" id="versions"></div>
    <div class="row"><button id="play">PLAY</button><button id="best">THIS ONE IS BEST</button><button id="reveal">REVEAL</button></div>
    <div id="why"></div>
    <table id="votes"><thead><tr><th>Track</th><th>Tempo</th><th>Your pick</th></tr></thead><tbody></tbody></table>
    </main>
    <script>
    const clips = __CLIPS__;
    const names = ["apple", "bungee"], pretty = {apple:"Apple", bungee:"Bungee"};
    let track = clips.tracks[0], tempo = clips.tempos[0], heard = 0, playing = false, revealed = false, audio = [];
    const orders = {}, votes = {};
    function order() {
      const key = track + "/" + tempo;
      if (!orders[key]) {
        const o = names.slice();
        for (let i = o.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [o[i], o[j]] = [o[j], o[i]]; }
        orders[key] = o;
      }
      return orders[key];
    }
    function load() {
      const wasPlaying = playing;
      stop();
      audio.forEach(a => { a.pause(); a.removeAttribute("src"); a.load(); });
      audio = order().map(name => {
        const a = new Audio(track + "-" + tempo + "-" + name + ".wav");
        a.preload = "auto"; a.loop = true; a.muted = true;
        return a;
      });
      draw();
      if (wasPlaying) start();
    }
    function start() {
      audio.forEach((a, i) => { a.currentTime = 0; a.muted = i !== heard; a.play(); });
      playing = true; draw();
    }
    function stop() { audio.forEach(a => a.pause()); playing = false; draw(); }
    function choose(i) {
      const from = audio[heard]; heard = i;
      audio.forEach((a, k) => { if (playing && a !== from) a.currentTime = from.currentTime; a.muted = k !== i; });
      draw();
    }
    function draw() {
      const box = document.getElementById("versions"); box.innerHTML = "";
      const o = order();
      ["A", "B", "C"].forEach((letter, i) => {
        const b = document.createElement("button");
        b.innerHTML = letter + "<small>" + (revealed ? pretty[o[i]] : "") + "</small>";
        b.className = i === heard ? "on" : "";
        b.onclick = () => choose(i);
        box.appendChild(b);
      });
      document.getElementById("play").textContent = playing ? "STOP" : "PLAY";
      const key = track + "/" + tempo;
      document.getElementById("best").className = votes[key] === o[heard] ? "on" : "";
      const body = document.querySelector("#votes tbody"); body.innerHTML = "";
      Object.keys(votes).sort().forEach(k => {
        const [t, p] = k.split("/");
        const known = revealed ? pretty[votes[k]] : ["A", "B", "C"][orders[k].indexOf(votes[k])];
        const row = document.createElement("tr");
        row.innerHTML = "<td>" + t + "</td><td>" + p + "%</td><td>" + known + "</td>";
        body.appendChild(row);
      });
      if (revealed) {
        const tally = {}; Object.values(votes).forEach(v => tally[v] = (tally[v] || 0) + 1);
        document.getElementById("why").textContent = names.map(n => pretty[n] + " " + (tally[n] || 0)).join("   ");
      } else document.getElementById("why").textContent = "";
    }
    function buttons(id, list, get, set, show) {
      const box = document.getElementById(id);
      list.forEach(value => {
        const b = document.createElement("button");
        b.textContent = show(value);
        b.dataset.value = value;
        b.onclick = () => { set(value); paint(); heard = 0; load(); };
        box.appendChild(b);
      });
      function paint() { box.querySelectorAll("button").forEach(b => b.className = String(get()) === b.dataset.value ? "on" : ""); }
      paint();
    }
    buttons("tracks", clips.tracks, () => track, v => track = v, v => v.replace(/-/g, " "));
    buttons("tempos", clips.tempos, () => tempo, v => tempo = v, v => v + "%");
    document.getElementById("play").onclick = () => playing ? stop() : start();
    document.getElementById("best").onclick = () => { votes[track + "/" + tempo] = order()[heard]; draw(); };
    document.getElementById("reveal").onclick = () => { revealed = !revealed; draw(); };
    addEventListener("keydown", e => {
      if (e.key === " ") { e.preventDefault(); playing ? stop() : start(); }
      if (["1", "2", "3"].includes(e.key)) choose(Number(e.key) - 1);
    });
    load();
    </script></body></html>
    """#
}
