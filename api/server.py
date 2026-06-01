import os
import subprocess
import glob
import json
from flask import Flask, request, jsonify
from flask_cors import CORS
import logging

app = Flask(__name__)
CORS(app)
logging.basicConfig(level=logging.INFO)

# Determine Wine prefix
WINEPREFIX = os.environ.get("WINEPREFIX", os.path.expanduser("~/.wine"))
PORT = int(os.environ.get("PORT", 5000))

# MT5 paths
MT5_EXPERTS = os.path.join(WINEPREFIX, "drive_c", "Program Files", "MetaTrader 5", "MQL5", "Experts")
MT5_INCLUDES = os.path.join(WINEPREFIX, "drive_c", "Program Files", "MetaTrader 5", "MQL5", "Include")

# MT4 paths
MT4_EXPERTS = os.path.join(WINEPREFIX, "drive_c", "Program Files", "HFM MT4", "MQL4", "Experts")
MT4_INCLUDES = os.path.join(WINEPREFIX, "drive_c", "Program Files", "HFM MT4", "MQL4", "Include")

def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    os.makedirs(os.path.join(path, "SMC"), exist_ok=True)

@app.route("/status", methods=["GET"])
def status():
    # Check if MT5/MT4 processes are running
    mt5 = False
    mt4 = False
    try:
        ps = subprocess.run(["ps", "aux"], capture_output=True, text=True)
        mt5 = "metaeditor" in ps.stdout.lower() or "terminal64" in ps.stdout.lower()
        mt4 = "terminal.exe" in ps.stdout.lower()
    except:
        pass
    return jsonify({"mt5_running": mt5, "mt4_running": mt4})

@app.route("/files/ea", methods=["GET"])
def list_ea():
    ensure_dir(MT5_EXPERTS)
    ensure_dir(MT4_EXPERTS)
    mt5_files = [os.path.basename(f) for f in glob.glob(os.path.join(MT5_EXPERTS, "*.ex5")) +
                 glob.glob(os.path.join(MT5_EXPERTS, "*.mq5"))]
    mt4_files = [os.path.basename(f) for f in glob.glob(os.path.join(MT4_EXPERTS, "*.ex4")) +
                 glob.glob(os.path.join(MT4_EXPERTS, "*.mq4"))]
    return jsonify({"mt5": mt5_files, "mt4": mt4_files})

@app.route("/upload/ea", methods=["POST"])
def upload_ea():
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400
    f = request.files["file"]
    if f.filename == "":
        return jsonify({"error": "Empty filename"}), 400
    ensure_dir(MT5_EXPERTS)
    f.save(os.path.join(MT5_EXPERTS, f.filename))
    return jsonify({"status": "ok", "file": f.filename, "target": "MT5 Experts"})

@app.route("/upload/ea4", methods=["POST"])
def upload_ea4():
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400
    f = request.files["file"]
    if f.filename == "":
        return jsonify({"error": "Empty filename"}), 400
    ensure_dir(MT4_EXPERTS)
    f.save(os.path.join(MT4_EXPERTS, f.filename))
    return jsonify({"status": "ok", "file": f.filename, "target": "MT4 Experts"})

@app.route("/upload/include", methods=["POST"])
def upload_include():
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400
    f = request.files["file"]
    if f.filename == "":
        return jsonify({"error": "Empty filename"}), 400
    dest = os.path.join(MT5_INCLUDES, "SMC")
    os.makedirs(dest, exist_ok=True)
    f.save(os.path.join(dest, f.filename))
    # Also copy to MT4 include
    dest4 = os.path.join(MT4_INCLUDES, "SMC")
    os.makedirs(dest4, exist_ok=True)
    with open(os.path.join(dest4, f.filename), "wb") as f4:
        f4.write(open(os.path.join(dest, f.filename), "rb").read())
    return jsonify({"status": "ok", "file": f.filename, "target": "MT5 + MT4 Includes/SMC"})

@app.route("/restart/mt5", methods=["POST"])
def restart_mt5():
    try:
        subprocess.run(["pkill", "-f", "terminal64"], check=False)
        subprocess.run(["pkill", "-f", "metaeditor"], check=False)
        subprocess.run(["wine", "C:\\Program Files\\MetaTrader 5\\terminal64.exe"], check=False)
        return jsonify({"status": "restarted", "target": "MT5"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/restart/mt4", methods=["POST"])
def restart_mt4():
    try:
        subprocess.run(["pkill", "-f", "terminal.exe"], check=False)
        subprocess.run(["wine", "C:\\Program Files\\HFM MT4\\terminal.exe"], check=False)
        return jsonify({"status": "restarted", "target": "MT4"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/deploy", methods=["POST"])
def deploy_bundle():
    """Upload EA + includes in one request (multipart zip or multiple files)."""
    results = {"ea": None, "includes": []}
    if "ea" in request.files:
        f = request.files["ea"]
        ensure_dir(MT5_EXPERTS)
        f.save(os.path.join(MT5_EXPERTS, f.filename))
        ensure_dir(MT4_EXPERTS)
        f.save(os.path.join(MT4_EXPERTS, f.filename.replace(".ex5", ".ex4").replace(".mq5", ".mq4")))
        results["ea"] = f.filename
    for key in request.files:
        if key.startswith("include"):
            f = request.files[key]
            for d in [os.path.join(MT5_INCLUDES, "SMC"), os.path.join(MT4_INCLUDES, "SMC")]:
                os.makedirs(d, exist_ok=True)
                f.save(os.path.join(d, f.filename))
            results["includes"].append(f.filename)
    return jsonify(results)

@app.route("/git-pull", methods=["POST"])
def git_pull():
    """Git pull and copy new EAs/includes."""
    repo = request.json.get("repo", "")
    dest = request.json.get("dest", "/tmp/smc-update")
    if not repo:
        return jsonify({"error": "repo URL required"}), 400
    try:
        if os.path.exists(dest):
            subprocess.run(["git", "-C", dest, "pull"], check=True)
        else:
            subprocess.run(["git", "clone", repo, dest], check=True)
        # Copy .ex5/.mq5 files to MT5 Experts
        for f in glob.glob(os.path.join(dest, "*.ex5")) + glob.glob(os.path.join(dest, "*.mq5")):
            with open(f, "rb") as src:
                with open(os.path.join(MT5_EXPERTS, os.path.basename(f)), "wb") as dst:
                    dst.write(src.read())
        return jsonify({"status": "ok", "synced_from": repo})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
