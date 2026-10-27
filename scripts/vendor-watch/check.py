# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compares the app's model catalogues with what each vendor serves.

Run through scripts/check-vendor-models.sh, which exports the catalogues first. Standard
library only, and Python 3.9 (the Command Line Tools' python3). Every request is made
here with urllib, so an API key never appears on a command line, and no error message
ever carries a request header. docs/vendor-watch.md describes the report.

Language lists are compared with their sources too, and never fail the release rule.

Exit status: 0 nothing to act on before a release, 1 the release rule fails (a catalogue
model the vendor no longer serves that is not deprecated or retired), 3 some vendor could
not be checked (no key, no network, an error), 64 bad usage. The shell script adds 2, a
failed build.
"""

import argparse
import base64
import datetime
import json
import os
import re
import socket
import ssl
import sys
import urllib.error
import urllib.request

TIMEOUT = 20
USER_AGENT = "speech-text-vendor-watch"
# A retired model leaves the catalogue this long after the vendor switched it off; its
# name and price go to the permanent archive (the model-lifecycle work).
RETENTION_MONTHS = 6
# Relative tolerance when comparing a price the API states with the catalogue's.
PRICE_TOLERANCE = 0.01
WATCHED_VENDORS = ["openAI", "groq", "anthropic", "elevenLabs"]
VENDOR_NAMES = {"openAI": "OpenAI", "groq": "Groq", "anthropic": "Anthropic", "elevenLabs": "ElevenLabs"}
KEY_NAMES = {"openAI": "OPENAI_API_KEY", "groq": "GROQ_API_KEY",
             "anthropic": "ANTHROPIC_API_KEY", "elevenLabs": "ELEVENLABS_API_KEY"}
# Packages whose releases bring new local models, by their Package.resolved identity.
MODEL_PACKAGES = ["fluidaudio", "argmax-oss-swift"]
# Hugging Face authors whose new repositories may be a model the local tier could offer,
# and what marks one as speech: FluidInference publishes OCR, embeddings and games too.
MODEL_AUTHORS = ["FluidInference", "argmaxinc"]
SPEECH_TASKS = {"automatic-speech-recognition", "voice-activity-detection", "audio-classification",
                "audio-to-audio", "text-to-speech"}
# A published language list (docs/design/model-details/) is read again by hand when its
# source has no reader below and it was checked longer ago than this.
LANGUAGE_RECHECK_DAYS = 180
# ISO 639-3 to 639-1, for the codes ElevenLabs writes; the catalogue keeps 639-1 where one
# exists and the 639-3 code otherwise (ast, ceb, fil, kea, luo, nso, umb, yue), so a code
# missing here is compared as it is, and a new one shows up as added.
ISO639_3_TO_1 = {
    "afr": "af", "amh": "am", "ara": "ar", "hye": "hy", "asm": "as", "aze": "az", "bel": "be",
    "ben": "bn", "bos": "bs", "bul": "bg", "mya": "my", "cat": "ca", "nya": "ny", "hrv": "hr",
    "ces": "cs", "dan": "da", "nld": "nl", "eng": "en", "est": "et", "fin": "fi", "fra": "fr",
    "ful": "ff", "glg": "gl", "lug": "lg", "kat": "ka", "deu": "de", "ell": "el", "guj": "gu",
    "hau": "ha", "heb": "he", "hin": "hi", "hun": "hu", "isl": "is", "ibo": "ig", "ind": "id",
    "gle": "ga", "ita": "it", "jpn": "ja", "jav": "jv", "kan": "kn", "kaz": "kk", "khm": "km",
    "kor": "ko", "kur": "ku", "kir": "ky", "lao": "lo", "lav": "lv", "lin": "ln", "lit": "lt",
    "ltz": "lb", "mkd": "mk", "msa": "ms", "mal": "ml", "mlt": "mt", "zho": "zh", "cmn": "zh",
    "mri": "mi", "mar": "mr", "mon": "mn", "nep": "ne", "nor": "no", "oci": "oc", "ori": "or",
    "pus": "ps", "fas": "fa", "pol": "pl", "por": "pt", "pan": "pa", "ron": "ro", "rus": "ru",
    "srp": "sr", "sna": "sn", "snd": "sd", "sin": "si", "slk": "sk", "slv": "sl", "som": "so",
    "spa": "es", "swa": "sw", "swe": "sv", "tam": "ta", "tgk": "tg", "tel": "te", "tha": "th",
    "tur": "tr", "ukr": "uk", "urd": "ur", "uzb": "uz", "vie": "vi", "cym": "cy", "wol": "wo",
    "xho": "xh", "zul": "zu", "yor": "yo",
}
SPEECH_NAME = re.compile(r"parakeet|whisper|asr|speech|stt|nemotron|canary|vad|voxtral|moonshine|phonon|"
                         r"transcri|diariz|audio", re.I)


class NotChecked(Exception):
    """A vendor whose list could not be read. Never an alarm about its models."""


# MARK: - HTTP

def request(url, headers=None, data=None, method=None):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers=dict({"User-Agent": USER_AGENT}, **(headers or {})))
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except (urllib.error.URLError, socket.timeout, ConnectionError, ssl.SSLError) as error:
        raise NotChecked("no answer from %s (%s)" % (url.split("/")[2], getattr(error, "reason", error)))


def get_json(url, headers=None):
    status, body = request(url, headers)
    if status != 200:
        raise NotChecked("HTTP %d: %s" % (status, error_message(body)))
    try:
        return json.loads(body)
    except ValueError:
        raise NotChecked("the reply is not JSON")


def error_message(body):
    """The vendor's own words from an error reply, never more than a line."""
    try:
        reply = json.loads(body)
    except ValueError:
        return body[:120].decode("utf-8", "replace")
    detail = reply.get("error") or reply.get("detail") or reply
    if isinstance(detail, dict):
        detail = detail.get("message") or detail.get("code") or json.dumps(detail)[:160]
    return str(detail)[:200]


# MARK: - Vendors

def openai_models(key):
    reply = get_json("https://api.openai.com/v1/models", {"Authorization": "Bearer " + key})
    return {m["id"]: {"shutdown": m.get("shutdown_date")} for m in reply["data"]}


def groq_models(key):
    reply = get_json("https://api.groq.com/openai/v1/models", {"Authorization": "Bearer " + key})
    models = {}
    for m in reply["data"]:
        info = {"active": m.get("active", True),
                "speech": "transcription" in (m.get("output_modalities") or [])}
        pricing = m.get("pricing") or {}
        if pricing.get("prompt") is not None:
            # Strings, dollars per token.
            info["price"] = {"input": float(pricing["prompt"]) * 1e6,
                             "output": float(pricing.get("completion") or 0) * 1e6,
                             "cachedInput": (float(pricing["input_cache_read"]) * 1e6
                                             if pricing.get("input_cache_read") is not None else None)}
        models[m["id"]] = info
    return models


def anthropic_models(key):
    models, after = {}, None
    while True:
        url = "https://api.anthropic.com/v1/models?limit=1000" + ("&after_id=" + after if after else "")
        reply = get_json(url, {"x-api-key": key, "anthropic-version": "2023-06-01"})
        for m in reply["data"]:
            models[m["id"]] = {}
        if not reply.get("has_more"):
            return models
        after = reply["last_id"]


QUOTED = re.compile(r"'([^']+)'")


def elevenlabs_models(key):
    """ElevenLabs' model list needs a key with `models_read`, and lists its voices' models
    besides. The speech-to-text endpoints name every model they accept in the validation
    error an unknown model_id gets, before anything is transcribed or billed: the upload
    endpoint in its JSON reply, the realtime socket in its first message."""
    probe = "vendor_watch_probe"
    boundary = "vendorwatch"
    body = ("--%s\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\n%s\r\n--%s--\r\n"
            % (boundary, probe, boundary)).encode()
    status, reply = request("https://api.elevenlabs.io/v1/speech-to-text", method="POST", data=body,
                            headers={"xi-api-key": key,
                                     "Content-Type": "multipart/form-data; boundary=" + boundary})
    message = error_message(reply)
    if "Available models" not in message:
        raise NotChecked("the upload endpoint did not list its models (HTTP %d: %s)" % (status, message))
    models = {m: {"endpoint": "upload"} for m in QUOTED.findall(message.split("Available models", 1)[1])}
    first = realtime_first_message(key, probe)
    if "Supported models" not in first:
        raise NotChecked("the realtime socket did not list its models: %s" % first[:160])
    for m in QUOTED.findall(first.split("Supported models", 1)[1]):
        models[m] = {"endpoint": "realtime"}
    return models


def realtime_first_message(key, model):
    """Opens the realtime WebSocket with an unknown model and returns the server's first
    text frame. A client sends no frames here, so none has to be masked."""
    host = "api.elevenlabs.io"
    handshake = ("GET /v1/speech-to-text/realtime?model_id=%s HTTP/1.1\r\nHost: %s\r\n"
                 "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                 "Sec-WebSocket-Key: %s\r\nxi-api-key: %s\r\n"
                 "User-Agent: %s\r\n\r\n"
                 % (model, host, base64.b64encode(os.urandom(16)).decode(), key, USER_AGENT))
    try:
        raw = socket.create_connection((host, 443), timeout=TIMEOUT)
        with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as sock:
            sock.sendall(handshake.encode())
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = sock.recv(4096)
                if not chunk:
                    raise NotChecked("the realtime socket closed during the handshake")
                data += chunk
            head, data = data.split(b"\r\n\r\n", 1)
            if b" 101 " not in head.split(b"\r\n", 1)[0]:
                raise NotChecked("the realtime socket refused the handshake: %s"
                                 % head.split(b"\r\n", 1)[0].decode("latin-1"))

            def read(count):
                nonlocal data
                while len(data) < count:
                    chunk = sock.recv(4096)
                    if not chunk:
                        raise NotChecked("the realtime socket closed before its first message")
                    data += chunk
                out, data = data[:count], data[count:]
                return out

            for _ in range(4):
                first, second = read(2)
                opcode, length = first & 0x0F, second & 0x7F
                if length == 126:
                    length = int.from_bytes(read(2), "big")
                elif length == 127:
                    length = int.from_bytes(read(8), "big")
                payload = read(length)
                if opcode == 1:
                    return payload.decode("utf-8", "replace")
                if opcode == 8:
                    return "closed: " + payload[2:].decode("utf-8", "replace")
            return ""
    except (OSError, ssl.SSLError) as error:
        raise NotChecked("no answer from %s (%s)" % (host, error))


FETCHERS = {"openAI": openai_models, "groq": groq_models,
            "anthropic": anthropic_models, "elevenLabs": elevenlabs_models}


# MARK: - Local models

def version_tuple(tag):
    return tuple(int(n) for n in re.findall(r"\d+", tag)[:3])


def package_releases(resolved_path):
    pins = {p["identity"]: p for p in json.load(open(resolved_path))["pins"]}
    out = []
    for identity in MODEL_PACKAGES:
        pin = pins.get(identity)
        if not pin:
            continue
        owner_repo = re.sub(r"\.git$", "", pin["location"].split("github.com/", 1)[1])
        pinned = pin["state"].get("version") or pin["state"]["revision"][:12]
        entry = {"package": owner_repo, "pinned": pinned, "newer": []}
        try:
            releases = get_json("https://api.github.com/repos/%s/releases?per_page=30" % owner_repo,
                                {"Accept": "application/vnd.github+json"})
            entry["newer"] = [{"tag": r["tag_name"], "date": (r.get("published_at") or "")[:10]}
                              for r in releases
                              if not r.get("draft") and not r.get("prerelease")
                              and version_tuple(r["tag_name"]) > version_tuple(pinned)]
        except NotChecked as error:
            entry["error"] = str(error)
        out.append(entry)
    return out


def huggingface_sources(models):
    """Each local model's repository — speech and chat alike: does the folder or files
    it installs still exist, and when did the repository last change."""
    repos, results = {}, []
    for model in models:
        if model.get("vendor") != "local":
            continue
        source = model.get("source")
        if not source:
            results.append({"id": model["id"], "problem": "the export names no source to check"})
            continue
        name = source["huggingFace"]
        if name not in repos:
            try:
                info = get_json("https://huggingface.co/api/models/" + name)
                files = [s["rfilename"] for s in info.get("siblings", [])]
                # Every folder a file sits in, at any depth: a required bundle may be inside
                # the source's own folder (Bark's two builds share one repository).
                repos[name] = {"lastModified": info.get("lastModified", "")[:10],
                               "folders": {"/".join(f.split("/")[:n]) for f in files
                                           for n in range(1, f.count("/") + 2)}}
            except NotChecked as error:
                repos[name] = {"error": str(error)}
        repo = repos[name]
        result = {"id": model["id"], "repo": name, "path": source.get("path")}
        if "error" in repo:
            result["error"] = repo["error"]
        else:
            result["lastModified"] = repo["lastModified"]
            path = source.get("path")
            wanted = ([path] if path else []) + [path + "/" + f if path else f for f in source.get("requiredFiles", [])]
            missing = [w for w in wanted if w not in repo["folders"]]
            if missing:
                result["missing"] = missing
        results.append(result)
    return results


# MARK: - Language lists

def whisper_languages(url):
    """The `LANGUAGES` table of Whisper's tokenizer, from the file the catalogue cites."""
    raw = url.replace("https://github.com/", "https://raw.githubusercontent.com/").replace("/blob/", "/")
    status, body = request(raw)
    if status != 200:
        raise NotChecked("HTTP %d from %s" % (status, raw))
    table = re.search(r"^LANGUAGES = \{(.*?)^\}", body.decode("utf-8", "replace"), re.S | re.M)
    if not table:
        raise NotChecked("no LANGUAGES table in %s" % raw)
    # Whisper writes Javanese "jw"; the catalogue writes the BCP-47 "jv".
    return {"jv" if c == "jw" else c for c in re.findall(r'^\s*"([a-z]+)":', table.group(1), re.M)}


def huggingface_languages(url):
    """The `language` list of a Hugging Face model card."""
    repo = url.split("huggingface.co/", 1)[1].strip("/")
    languages = (get_json("https://huggingface.co/api/models/" + repo).get("cardData") or {}).get("language")
    if not languages:
        raise NotChecked("the model card of %s lists no language" % repo)
    return set([languages] if isinstance(languages, str) else languages)


def elevenlabs_languages(url):
    """The list on an ElevenLabs documentation page, from its Markdown version: the line with
    the most "Name (xyz)" codes is the full list (the others are its accuracy buckets)."""
    status, body = request(url.rstrip("/") + ".md")
    if status != 200:
        raise NotChecked("HTTP %d from %s.md" % (status, url))
    lines = body.decode("utf-8", "replace").splitlines()
    codes = max((re.findall(r"\(([a-z]{3})\)", line) for line in lines), key=len, default=[])
    if len(codes) < 20:
        raise NotChecked("no language list found on %s" % url)
    return {ISO639_3_TO_1.get(c, c) for c in codes}


def language_reader(url):
    if url.startswith("https://github.com/openai/whisper/"):
        return whisper_languages
    if url.startswith("https://huggingface.co/"):
        return huggingface_languages
    if url.startswith("https://elevenlabs.io/docs/"):
        return elevenlabs_languages
    return None


def language_lists(catalogue, today):
    """Each published language list the catalogue cites, read again from its source:
    languages the source has that the catalogue lacks, and the reverse. A source with no
    reader is listed for the weekly agent to read, and flagged once it is old."""
    groups, unpublished = {}, []
    for model in catalogue["speech"]:
        languages = model.get("languages") or {}
        name = "%s `%s`" % (VENDOR_NAMES.get(model["vendor"], model["vendor"]), model["id"])
        if languages.get("kind") == "listed":
            group = groups.setdefault(languages["source"], {"ours": set(), "checked": languages["checked"], "models": []})
            group["ours"] |= set(languages["codes"])
            group["checked"] = min(group["checked"], languages["checked"])
            group["models"].append(name)
        elif languages.get("kind") == "unpublished":
            unpublished.append(name)
    results = []
    for source, group in sorted(groups.items()):
        result = {"source": source, "models": group["models"], "checked": group["checked"]}
        reader = language_reader(source)
        if reader is None:
            checked = datetime.date.fromisoformat(group["checked"])
            result["manual"] = True
            result["stale"] = (today - checked).days > LANGUAGE_RECHECK_DAYS
        else:
            try:
                theirs = reader(source)
                result["added"] = sorted(theirs - group["ours"])
                result["dropped"] = sorted(group["ours"] - theirs)
            except NotChecked as error:
                result["error"] = str(error)
        results.append(result)
    return results, unpublished


def new_repositories(since):
    out, errors = [], []
    for author in MODEL_AUTHORS:
        try:
            listed = get_json("https://huggingface.co/api/models?author=%s&sort=createdAt&direction=-1&limit=100"
                              % author)
        except NotChecked as error:
            errors.append("%s: %s" % (author, error))
            continue
        for repo in listed:
            created = (repo.get("createdAt") or "")[:10]
            if created and created >= since:
                task = repo.get("pipeline_tag") or ""
                out.append({"id": repo["id"], "created": created, "task": task,
                            "speech": task in SPEECH_TASKS or bool(SPEECH_NAME.search(repo["id"]))})
    return out, errors


# MARK: - Comparison

SNAPSHOT_DATE = re.compile(r"-\d{4}-?\d{2}-?\d{2}$|-\d{4}$")
OPENAI_NOT_TEXT = re.compile(r"tts|dall-e|image|embedding|moderation|davinci|babbage|sora|computer-use|"
                             r"search|codex|audio|realtime(?!-whisper)|chat-latest|instruct")
GROQ_NOT_TEXT = re.compile(r"guard|orpheus|tts|playai")


def relevant(vendor, model_id):
    """Whether a vendor ID could be a model for dictation or AI Rewrite — the rest of a
    135-model list (voices, images, embeddings, dated snapshots of an alias) is noise."""
    if vendor == "anthropic":
        # Every Anthropic model may carry a date in its ID, so none is a mere snapshot.
        return True
    if SNAPSHOT_DATE.search(model_id):
        return False
    if vendor == "openAI":
        if re.search(r"transcribe|whisper", model_id):
            return True
        return bool(re.match(r"(gpt-\d|o\d)", model_id)) and not OPENAI_NOT_TEXT.search(model_id)
    if vendor == "groq":
        return not GROQ_NOT_TEXT.search(model_id)
    return True


def add_months(day, months):
    month = day.month - 1 + months
    year, month = day.year + month // 12, month % 12 + 1
    last = [31, 29 if year % 4 == 0 and (year % 100 or year % 400 == 0) else 28, 31, 30, 31, 30,
            31, 31, 30, 31, 30, 31][month - 1]
    return datetime.date(year, month, min(day.day, last))


def catalogue_entries(catalogue):
    """(vendor, id, kind, lifecycle, endpoint) for every watched catalogue model, with each
    realtime model's upload twin as a requirement of its own."""
    entries = []
    for m in catalogue["speech"]:
        if m["vendor"] not in WATCHED_VENDORS:
            continue
        endpoint = "realtime" if m["delivery"] == "realtime" else "upload"
        entries.append((m["vendor"], m["id"], "speech", m["lifecycle"], endpoint))
        if m.get("uploadModel"):
            entries.append((m["vendor"], m["uploadModel"], "upload twin of " + m["id"], m["lifecycle"], "upload"))
    for m in catalogue["chat"]:
        if m["vendor"] in WATCHED_VENDORS:
            entries.append((m["vendor"], m["id"], "chat", m["lifecycle"], None))
    seen, unique = set(), []
    for e in entries:
        if (e[0], e[1], e[2]) not in seen:
            seen.add((e[0], e[1], e[2]))
            unique.append(e)
    return unique


DATED = re.compile(r"-\d{8}$")


def served_entry(vendor, models, model_id):
    """The vendor's entry for a catalogue ID. Anthropic's aliases (`claude-haiku-4-5`) may
    be listed only as their dated snapshot (`claude-haiku-4-5-20251001`)."""
    if model_id in models:
        return models[model_id]
    if vendor == "anthropic":
        for served_id, info in models.items():
            if DATED.search(served_id) and DATED.sub("", served_id) == model_id:
                return info
    return None


def compare(catalogue, served, today):
    gone, going, deprecated_ok, expired, drift, ok = [], [], [], [], [], 0
    for vendor, model_id, kind, lifecycle, endpoint in catalogue_entries(catalogue):
        state, shutdown = lifecycle.get("state", "current"), lifecycle.get("shutdownDate")
        known_going = state in ("deprecated", "retired")
        # The catalogue's own dates, whether or not the vendor answered today.
        if shutdown and known_going and not kind.startswith("upload twin"):
            day = datetime.date.fromisoformat(shutdown)
            remove_on = add_months(day, RETENTION_MONTHS)
            if state == "retired" and remove_on <= today:
                expired.append((vendor, model_id, kind, shutdown, "remove from " + remove_on.isoformat()))
            elif state == "deprecated" and day < today:
                expired.append((vendor, model_id, kind, shutdown, "past its shutdown: mark it retired"))
        models = served.get(vendor)
        if models is None:
            continue
        info = served_entry(vendor, models, model_id)
        if info is None or (endpoint and info.get("endpoint") not in (None, endpoint)):
            (deprecated_ok if known_going else gone).append((vendor, model_id, kind, state))
            continue
        ok += 1
        vendor_shutdown = info.get("shutdown")
        if vendor_shutdown or info.get("active") is False:
            if not known_going:
                going.append((vendor, model_id, kind, vendor_shutdown or "inactive", state))
            elif shutdown != vendor_shutdown and vendor_shutdown:
                going.append((vendor, model_id, kind, vendor_shutdown, state + ", catalogue says " + str(shutdown)))
    # Prices, where the API states them (Groq's chat models).
    for m in catalogue["chat"]:
        info = served.get(m["vendor"], {}).get(m["id"]) if served.get(m["vendor"]) else None
        if not info or "price" not in info:
            continue
        listed, price = info["price"], m["price"]
        if price["kind"] != "listed":
            drift.append((m["vendor"], m["id"], "catalogue: %s" % price["kind"], format_rates(listed)))
            continue
        ours = {"input": price["inputPerMillion"], "output": price["outputPerMillion"],
                "cachedInput": price["cachedInputPerMillion"]}
        theirs = dict(listed)
        if theirs["cachedInput"] is None:
            theirs["cachedInput"] = theirs["input"]
        if any(abs(ours[k] - theirs[k]) > PRICE_TOLERANCE * max(theirs[k], 1e-9) for k in ours):
            drift.append((m["vendor"], m["id"], format_rates(ours), format_rates(theirs)))
    return {"gone": gone, "going": going, "deprecatedGone": deprecated_ok, "expired": expired,
            "drift": drift, "ok": ok}


def format_rates(rates):
    cached = rates.get("cachedInput")
    return "$%s in / $%s cached / $%s out per M" % (
        trim(rates["input"]), trim(cached if cached is not None else rates["input"]), trim(rates["output"]))


def trim(value):
    return ("%.4f" % value).rstrip("0").rstrip(".")


def candidates(catalogue, served, previous):
    listed = {(m["vendor"], m["id"]) for m in catalogue["speech"] + catalogue["chat"]}
    listed |= {(m["vendor"], m["uploadModel"]) for m in catalogue["speech"] if m.get("uploadModel")}
    new, absent = {}, {}
    for vendor, models in served.items():
        if models is None:
            continue
        before = previous.get(vendor) if previous else None
        for model_id in sorted(models):
            if ((vendor, model_id) in listed or (vendor, DATED.sub("", model_id)) in listed
                    or not relevant(vendor, model_id)):
                continue
            absent.setdefault(vendor, []).append(model_id)
            if before is not None and model_id not in before:
                new.setdefault(vendor, []).append(model_id)
    return new, absent


# MARK: - Report

def report(args, catalogue, served, problems, result, new, absent, packages, sources,
           repos, repo_errors, previous_date, today, languages=([], [])):
    lines = ["# Vendor watch — %s" % today.isoformat(), "",
             "Catalogue: `%s`, prices checked %s. New IDs and repositories since %s."
             % (args.commit, catalogue["pricesChecked"], args.since), ""]
    gate = bool(result["gone"]) or any(s.get("missing") for s in sources)
    unchecked = sorted(problems)
    if gate:
        lines.append("**Release rule fails**: the catalogue offers a model the vendor no longer serves.")
    elif unchecked:
        lines.append("**Not every vendor was checked** (%s): this is not an all-clear."
                     % ", ".join(VENDOR_NAMES[v] for v in unchecked))
    else:
        lines.append("Release rule passes: every vendor checked, nothing gone that is not already deprecated.")
    lines.append("")

    lines += ["## Not checked", ""]
    if unchecked:
        lines += ["- %s: %s" % (VENDOR_NAMES[v], problems[v]) for v in unchecked]
    else:
        lines.append("Every vendor answered.")
    lines.append("")

    lines += ["## Gone: in the catalogue, not served by the vendor", "",
              "The lists are per account: confirm on the vendor's deprecation page before acting.", ""]
    if result["gone"]:
        lines += ["- **%s `%s`** (%s, %s)" % (VENDOR_NAMES[v], i, k, s) for v, i, k, s in result["gone"]]
    else:
        lines.append("None.")
    if result["deprecatedGone"]:
        lines += ["", "Already deprecated or retired in the catalogue, and gone at the vendor (expected):", ""]
        lines += ["- %s `%s` (%s, %s)" % (VENDOR_NAMES[v], i, k, s) for v, i, k, s in result["deprecatedGone"]]
    lines.append("")

    lines += ["## Shutdown announced by the vendor's API", ""]
    if result["going"]:
        lines += ["- **%s `%s`** (%s): shuts down %s; catalogue: %s" % (VENDOR_NAMES[v], i, k, d, s)
                  for v, i, k, d, s in result["going"]]
    else:
        lines.append("None. (Only OpenAI's list carries a `shutdown_date`, and Groq's an `active` flag.)")
    lines.append("")

    lines += ["## Past their shutdown: retire, or remove in the next release", ""]
    if result["expired"]:
        lines += ["- %s `%s` (%s): shut down %s; %s" % (VENDOR_NAMES[v], i, k, s, r)
                  for v, i, k, s, r in result["expired"]]
    else:
        lines.append("None.")
    lines.append("")

    lines += ["## Prices that differ from the vendor's API", "",
              "Only Groq's model list states prices; every other price is checked by hand (docs/prices.md).", ""]
    if result["drift"]:
        lines += ["- %s `%s`: catalogue %s, API %s" % (VENDOR_NAMES[v], i, ours, theirs)
                  for v, i, ours, theirs in result["drift"]]
    else:
        lines.append("None.")
    lines.append("")

    lists, unpublished = languages
    lines += ["## Language lists", "",
              "Each list the catalogue cites, read again from its source. A language added or dropped "
              "there changes the rows' count and their \"No …\" badges: update the codes and the date "
              "in ModelLanguages.swift (or the model's entry).", ""]
    for entry in lists:
        models = ", ".join(entry["models"])
        if "error" in entry:
            state = "not checked: %s" % entry["error"]
        elif entry.get("manual"):
            state = ("**read it again by hand** (checked %s)" if entry["stale"] else "read by hand (checked %s)") \
                % entry["checked"]
        elif entry["added"] or entry["dropped"]:
            parts = (["added at the source: %s" % ", ".join(entry["added"])] if entry["added"] else []) + \
                    (["dropped at the source: %s" % ", ".join(entry["dropped"])] if entry["dropped"] else [])
            state = "**%s**" % "; ".join(parts)
        else:
            state = "matches"
        lines.append("- %s (%s): %s" % (entry["source"], models, state))
    if not lists:
        lines.append("The export carries no language lists.")
    if unpublished:
        lines += ["", "No published list (the weekly agent checks whether the vendor now publishes one): %s."
                  % ", ".join(unpublished)]
    lines.append("")

    lines += ["## New at the vendor", ""]
    if previous_date is None:
        lines.append("No earlier snapshot, so nothing can be called new yet; every relevant ID not in the "
                     "catalogue is listed below.")
    elif any(new.values()):
        lines.append("Not in the catalogue, and not served at the previous run (%s):" % previous_date)
        lines.append("")
        lines += ["- %s: %s" % (VENDOR_NAMES[v], ", ".join("`%s`" % i for i in ids)) for v, ids in sorted(new.items())]
    else:
        lines.append("Nothing new since %s." % previous_date)
    lines += ["", "<details><summary>Every relevant vendor ID not in the catalogue</summary>", ""]
    lines += ["- %s: %s" % (VENDOR_NAMES[v], ", ".join("`%s`" % i for i in ids)) for v, ids in sorted(absent.items())]
    lines += ["", "</details>", ""]

    lines += ["## Local models", "", "| Package | Pinned | Newer releases |", "|---|---|---|"]
    for p in packages:
        newer = p.get("error") or (", ".join("%s (%s)" % (r["tag"], r["date"]) for r in p["newer"]) or "none")
        lines.append("| %s | %s | %s |" % (p["package"], p["pinned"], newer))
    lines += ["", "| Model | Repository | Changed | Files |", "|---|---|---|---|"]
    for s in sources:
        if "problem" in s:
            lines.append("| `%s` | — | — | **%s** |" % (s["id"], s["problem"]))
            continue
        changed = s.get("lastModified", "")
        if changed and changed >= args.since:
            changed = "**%s**" % changed
        files = ("not checked: " + s["error"]) if "error" in s else (
            "**missing: %s**" % ", ".join(s["missing"]) if s.get("missing") else "present")
        lines.append("| `%s` | %s%s | %s | %s |" % (s["id"], s["repo"], "/" + s["path"] if s.get("path") else "",
                                                     changed, files))
    lines += ["", "New repositories by %s since %s:" % (" and ".join(MODEL_AUTHORS), args.since), ""]
    speech_repos = [r for r in repos if r["speech"]]
    if speech_repos:
        lines += ["- **`%s`** (%s%s)" % (r["id"], r["created"], ", " + r["task"] if r["task"] else "")
                  for r in speech_repos]
    else:
        lines.append("None that looks like speech.")
    others = [r["id"] for r in repos if not r["speech"]]
    if others:
        lines.append("- and %d more that do not: %s" % (len(others), ", ".join("`%s`" % o for o in others)))
    lines += ["- not checked: %s" % e for e in repo_errors]
    lines.append("")
    return "\n".join(lines), gate, bool(unchecked)


# MARK: - Main

def read_keys(path):
    keys = {}
    if path and os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                name, value = line.split("=", 1)
                keys[name.strip().removeprefix("export ").strip()] = value.strip().strip("'\"")
    for name in KEY_NAMES.values():
        if os.environ.get(name):
            keys[name] = os.environ[name]
    return keys


def latest_snapshot(folder, today):
    if not folder or not os.path.isdir(folder):
        return None, None
    days = sorted(f[:-5] for f in os.listdir(folder)
                  if re.match(r"\d{4}-\d{2}-\d{2}\.json$", f) and f[:-5] < today.isoformat())
    if not days:
        return None, None
    return json.load(open(os.path.join(folder, days[-1] + ".json"))), days[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--catalogue", required=True)
    parser.add_argument("--resolved", required=True)
    parser.add_argument("--keys")
    parser.add_argument("--commit", default="unknown")
    parser.add_argument("--snapshots", help="folder of earlier runs' vendor lists, outside the repository")
    parser.add_argument("--since", help="yyyy-mm-dd; default: the previous snapshot, else a week ago")
    parser.add_argument("--out")
    args = parser.parse_args()

    today = datetime.date.today()
    catalogue = json.load(open(args.catalogue))
    keys = read_keys(args.keys)
    previous, previous_date = latest_snapshot(args.snapshots, today)
    if not args.since:
        args.since = previous_date or (today - datetime.timedelta(days=7)).isoformat()

    served, problems = {}, {}
    for vendor in WATCHED_VENDORS:
        key = keys.get(KEY_NAMES[vendor])
        if not key:
            served[vendor] = None
            problems[vendor] = "no %s in the keys file or the environment" % KEY_NAMES[vendor]
            continue
        try:
            served[vendor] = FETCHERS[vendor](key)
        except NotChecked as error:
            served[vendor] = None
            problems[vendor] = str(error)

    result = compare(catalogue, served, today)
    new, absent = candidates(catalogue, served, (previous or {}).get("vendors"))
    packages = package_releases(args.resolved)
    sources = huggingface_sources(catalogue["speech"] + catalogue["chat"])
    repos, repo_errors = new_repositories(args.since)
    languages = language_lists(catalogue, today)
    text, gate, unchecked = report(args, catalogue, served, problems, result, new, absent, packages, sources,
                                   repos, repo_errors, previous_date, today, languages)
    if args.out:
        with open(args.out, "w") as out:
            out.write(text + "\n")
    print(text)

    if args.snapshots:
        os.makedirs(args.snapshots, exist_ok=True)
        snapshot = {"date": today.isoformat(), "commit": args.commit,
                    # A vendor not checked today keeps its last known list, so the next run
                    # does not call its whole list new.
                    "vendors": {v: (sorted(served[v]) if served.get(v) is not None
                                    else ((previous or {}).get("vendors") or {}).get(v))
                                for v in WATCHED_VENDORS}}
        with open(os.path.join(args.snapshots, today.isoformat() + ".json"), "w") as out:
            json.dump(snapshot, out, indent=1, sort_keys=True)

    if gate:
        return 1
    return 3 if unchecked else 0


if __name__ == "__main__":
    sys.exit(main())
