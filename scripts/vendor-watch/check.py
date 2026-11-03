# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compares the app's model catalogues with what each vendor serves.

Run through scripts/check-vendor-models.sh, which exports the catalogues first. Standard
library only, and Python 3.9 (the Command Line Tools' python3). Every request is made
here with urllib, so an API key never appears on a command line, and no error message
ever carries a request header. docs/vendor-watch.md describes the report.

Language lists are compared with their sources too, and never fail the release rule.
Each vendor's deprecation page is read by its tables, and its changelog for the lines that
are new since the stored copy (docs/vendor-watch.md › The vendors' pages).

Exit status: 0 nothing to act on before a release, 1 the release rule fails (a catalogue
model the vendor no longer serves that is not deprecated or retired), 3 some vendor, or its
deprecation page, could not be checked (no key, no network, an error, a page that changed
shape), 64 bad usage. The shell script adds 2, a
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
# The prices other than Groq's are checked by hand (docs/prices.md); the report asks for it
# again once the catalogue's date is older than this.
PRICE_RECHECK_DAYS = 60
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


def github_headers():
    """A hosted runner shares its address with others, and GitHub allows an address 60
    unauthenticated requests an hour: with GITHUB_TOKEN set, the requests are the token's."""
    headers = {"Accept": "application/vnd.github+json"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    return headers


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
                                github_headers())
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
                repos[name] = {"lastModified": info.get("lastModified", "")[:10],
                               "top": {s["rfilename"].split("/")[0] for s in info.get("siblings", [])}}
            except NotChecked as error:
                repos[name] = {"error": str(error)}
        repo = repos[name]
        result = {"id": model["id"], "repo": name, "path": source.get("path")}
        if "error" in repo:
            result["error"] = repo["error"]
        else:
            result["lastModified"] = repo["lastModified"]
            wanted = ([source["path"]] if source.get("path") else []) + source.get("requiredFiles", [])
            missing = [w for w in wanted if w not in repo["top"]]
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
    reader is listed to read by hand, and flagged once it is old."""
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


# MARK: - Vendor pages

# Each vendor's deprecation page, in its Markdown version: a table per announcement (and,
# at Anthropic, one with every model's state). The API lists say what is served; these
# pages say when a model goes and what replaces it. ElevenLabs publishes no such page.
DEPRECATION_PAGES = {
    "openAI": "https://developers.openai.com/api/docs/deprecations.md",
    "groq": "https://console.groq.com/docs/deprecations.md",
    "anthropic": "https://platform.claude.com/docs/en/about-claude/model-deprecations.md",
}
# Pages read for their new lines only: announcements, preview models withdrawn without a
# deprecation entry, and whether OpenAI now publishes a language list for its speech
# models. Never part of the release rule.
TEXT_PAGES = [
    ("openAI", "openai-changelog", "https://developers.openai.com/api/docs/changelog.md"),
    ("openAI", "openai-speech-to-text", "https://developers.openai.com/api/docs/guides/speech-to-text.md"),
    ("groq", "groq-changelog", "https://console.groq.com/docs/changelog.md"),
    ("groq", "groq-models", "https://console.groq.com/docs/models.md"),
    ("elevenLabs", "elevenlabs-changelog", "https://elevenlabs.io/docs/changelog.md"),
    ("elevenLabs", "elevenlabs-models", "https://elevenlabs.io/docs/overview/models.md"),
]
# A new line on a text page is reported when it names a catalogue model or says one of these.
PAGE_WORDS = re.compile(r"deprecat|shut ?down|retire|sunset|speech[- ]to[- ]text|transcri|\bscribe\b|whisper", re.I)
# A new line that names a catalogue model and says one of these is a finding of its own,
# filed against the model; any other line is only shown in the report.
LIFECYCLE_WORDS = re.compile(r"deprecat|shut ?down|retire|sunset|discontinu|end of life|legacy", re.I)
PAGE_LINES_SHOWN = 30
DATE_FORMATS = ["%B %d, %Y", "%b %d, %Y", "%m/%d/%y", "%Y-%m-%d"]


def read_page(url):
    status, body = request(url)
    if status != 200:
        raise NotChecked("HTTP %d from %s" % (status, url))
    return body.decode("utf-8", "replace")


def table_cells(line):
    """A Markdown table row's cells; `\\|` inside a cell is a literal bar."""
    inner = line.strip()
    inner = inner[1:] if inner.startswith("|") else inner
    inner = inner[:-1] if inner.endswith("|") and not inner.endswith("\\|") else inner
    return [cell.replace("\\|", "|").strip() for cell in re.split(r"(?<!\\)\|", inner)]


def markdown_tables(text):
    """(heading, header cells, rows) for every table, with the nearest heading above it."""
    tables, heading, lines = [], "", text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("#"):
            heading = re.sub(r"\]\(#[^)]*\)", "]", line.lstrip("#").strip()).replace("[", "").replace("]", "")
        if (line.lstrip().startswith("|") and i + 1 < len(lines)
                and re.match(r"^\s*\|?\s*:?-{3,}", lines[i + 1])):
            header, rows, i = table_cells(line), [], i + 2
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                rows.append(table_cells(lines[i]))
                i += 1
            tables.append((heading, header, rows))
            continue
        i += 1
    return tables


def page_date(text):
    """(date or None, whether it is only a "not sooner than" bound)."""
    text = text.strip().rstrip(".")
    bound = text.lower().startswith("not sooner than")
    if bound:
        text = text[len("not sooner than"):].strip()
    for fmt in DATE_FORMATS:
        try:
            return datetime.datetime.strptime(text, fmt).date(), bound
        except ValueError:
            pass
    return None, bound


def cell_ids(cell):
    """The model IDs a cell names: those in backticks if any, else its words split on "or"."""
    quoted = re.findall(r"`([^`]+)`", cell)
    if quoted:
        return [q.strip() for q in quoted if not q.startswith("/") and not q.startswith("v1/")]
    if cell.strip() in ("", "—", "-", "N/A"):
        return []
    return [p.strip() for p in re.split(r"\s+or\s+|\s+and\s+|,\s*", cell) if p.strip()]


def column(header, *words, avoid=None):
    for index, name in enumerate(header):
        name = name.lower()
        if all(w in name for w in words) and not (avoid and avoid in name):
            return index
    return None


def deprecation_rows(vendor, text):
    """Every row of every table this reader knows on a deprecation page: the IDs it names,
    the date (shutdown, retirement, or Anthropic's "not sooner than" bound), the
    replacement, and Anthropic's current state. No known table, or a known table with no
    rows, means the page changed shape: the vendor is then not checked, never all-clear."""
    rows = []
    for heading, header, body in markdown_tables(text):
        model = column(header, "model", avoid="replacement")
        date = column(header, "shutdown date")
        if date is None:
            date = column(header, "retirement date")
        if model is None or date is None:
            continue
        replacement = column(header, "replacement")
        state = column(header, "current state")
        if not body:
            raise NotChecked("a deprecation table with no rows under \"%s\"" % heading)
        for cells in body:
            if len(cells) < len(header):
                continue
            day, bound = page_date(cells[date])
            rows.append({"ids": cell_ids(cells[model]), "date": day, "bound": bound,
                         "replacement": cell_ids(cells[replacement]) if replacement is not None else [],
                         "state": cells[state] if state is not None else "Deprecated",
                         "heading": heading})
    if not rows:
        raise NotChecked("no deprecation table this script can read")
    return rows


def page_entry(vendor, rows, model_id):
    """What a deprecation page says about one catalogue ID, merged across its tables."""
    found = {"listed": False, "date": None, "bound": None, "replacement": [], "state": None}
    for row in rows:
        ids = row["ids"]
        if model_id not in ids and not (vendor == "anthropic"
                                        and any(DATED.sub("", i) == model_id for i in ids)):
            continue
        if row["state"].lower() in ("deprecated", "retired"):
            found["listed"] = True
            if row["date"] and not row["bound"]:
                found["date"] = row["date"]
            found["replacement"] = found["replacement"] or row["replacement"]
            found["state"] = found["state"] or row["state"]
        elif row["state"].lower() == "active":
            found["state"] = "Active"
            if row["bound"]:
                found["bound"] = row["date"]
    return found


def deprecation_pages(catalogue, gone, today, reader=read_page):
    """Each catalogue model checked against its vendor's deprecation page. Returns the
    findings, the URL that confirms each per-account "gone", and the pages not read."""
    findings, confirmed, problems = [], {}, {}
    entries = catalogue_entries(catalogue)
    for vendor, url in sorted(DEPRECATION_PAGES.items()):
        try:
            rows = deprecation_rows(vendor, reader(url))
        except NotChecked as error:
            problems[vendor] = str(error)
            continue
        for v, model_id, kind, lifecycle, _ in entries:
            if v != vendor:
                continue
            page = page_entry(vendor, rows, model_id)
            state, shutdown = lifecycle.get("state", "current"), lifecycle.get("shutdownDate")
            if page["listed"]:
                if (vendor, model_id) in gone:
                    confirmed[(vendor, model_id)] = url
                if state not in ("deprecated", "retired"):
                    findings.append({"vendor": vendor, "id": model_id, "kind": kind, "type": "deprecation_listed",
                                     "date": page["date"], "replacement": page["replacement"],
                                     "state": state, "url": url})
                elif page["date"] and shutdown and page["date"].isoformat() != shutdown:
                    findings.append({"vendor": vendor, "id": model_id, "kind": kind,
                                     "type": "deprecation_date_changed", "date": page["date"],
                                     "replacement": page["replacement"], "state": state,
                                     "catalogue": shutdown, "url": url})
            elif (page["state"] == "Active" and page["bound"] and page["bound"] <= today
                  and state not in ("deprecated", "retired")):
                findings.append({"vendor": vendor, "id": model_id, "kind": kind,
                                 "type": "retirement_window_open", "date": page["bound"],
                                 "replacement": [], "state": state, "url": url})
    return findings, confirmed, problems


def page_snapshot(folder, slug, today):
    """The latest stored copy of a text page from before today, and where today's goes.
    Two copies are kept per page."""
    if not folder:
        return None, None, None
    pages = os.path.join(folder, "pages", slug)
    os.makedirs(pages, exist_ok=True)
    days = sorted(f[:-3] for f in os.listdir(pages) if re.match(r"\d{4}-\d{2}-\d{2}\.md$", f))
    earlier = [d for d in days if d < today.isoformat()]
    for old in earlier[:-1]:
        os.remove(os.path.join(pages, old + ".md"))
    previous = None
    if earlier:
        with open(os.path.join(pages, earlier[-1] + ".md"), encoding="utf-8") as f:
            previous = f.read()
    return previous, (earlier[-1] if earlier else None), os.path.join(pages, today.isoformat() + ".md")


def new_page_lines(previous, current, model_ids):
    """Lines of `current` that `previous` did not have, compared as sets so that moved
    blocks are not new, kept when they name a catalogue model or say a watched word.
    Each comes with the headings above it and the catalogue IDs it names. Headings and
    code samples are context, never a line of their own."""
    before = {line.strip() for line in previous.splitlines()}
    fenced = False
    patterns = [(i, re.compile(r"(?<![\w./-])%s(?![\w/-]|\.\w)" % re.escape(i))) for i in model_ids]
    headings, out = {}, []
    for line in current.splitlines():
        text = line.strip()
        if text.startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        if text.startswith("#"):
            level = len(text) - len(text.lstrip("#"))
            headings = {k: v for k, v in headings.items() if k < level}
            headings[level] = re.sub(r"\]\(#[^)]*\)", "]", text.lstrip("#").strip()).replace("[", "").replace("]", "")
            continue
        if not text or text in before:
            continue
        named = [i for i, p in patterns if p.search(text)]
        if named or PAGE_WORDS.search(text):
            out.append({"line": text, "section": " › ".join(v for _, v in sorted(headings.items())),
                        "models": named})
    return out


def text_pages(catalogue, snapshots, today, reader=read_page):
    """The new lines of each text page since its stored copy."""
    ids = {}
    for vendor, model_id, _, _, _ in catalogue_entries(catalogue):
        ids.setdefault(vendor, set()).add(model_id)
    results = []
    for vendor, slug, url in TEXT_PAGES:
        result = {"vendor": vendor, "slug": slug, "url": url}
        try:
            current = reader(url)
        except NotChecked as error:
            result["error"] = str(error)
            results.append(result)
            continue
        if not snapshots:
            result["uncompared"] = True
            results.append(result)
            continue
        previous, since, path = page_snapshot(snapshots, slug, today)
        if path:
            with open(path, "w", encoding="utf-8") as f:
                f.write(current)
        if previous is None:
            result["baseline"] = True
        else:
            result["since"] = since
            result["lines"] = new_page_lines(previous, current, sorted(ids.get(vendor, ())))
        results.append(result)
    return results


# MARK: - Report

def report(args, catalogue, served, problems, result, new, absent, packages, sources,
           repos, repo_errors, previous_date, today, languages=([], []), pages=None):
    pages = pages or {"findings": [], "confirmed": {}, "problems": {}, "text": []}
    lines = ["# Vendor watch — %s" % today.isoformat(), "",
             "Catalogue: `%s`, prices checked %s. New IDs and repositories since %s."
             % (args.commit, catalogue["pricesChecked"], args.since), ""]
    gate = bool(result["gone"]) or any(s.get("missing") for s in sources)
    unchecked = sorted(problems)
    unread = sorted(pages["problems"])
    if gate:
        lines.append("**Release rule fails**: the catalogue offers a model the vendor no longer serves.")
    elif unchecked or unread:
        lines.append("**Not every vendor was checked** (%s): this is not an all-clear."
                     % ", ".join(VENDOR_NAMES[v] for v in unchecked)
                     + "".join("; %s's deprecation page" % VENDOR_NAMES[v] for v in unread))
    else:
        lines.append("Release rule passes: every vendor checked, nothing gone that is not already deprecated.")
    lines.append("")

    lines += ["## Not checked", ""]
    lines += ["- %s: %s" % (VENDOR_NAMES[v], problems[v]) for v in unchecked]
    lines += ["- %s's deprecation page (%s): %s" % (VENDOR_NAMES[v], DEPRECATION_PAGES[v], pages["problems"][v])
              for v in unread]
    if not unchecked and not unread:
        lines.append("Every vendor answered, and every deprecation page was read.")
    lines.append("")

    lines += ["## Gone: in the catalogue, not served by the vendor", "",
              "OpenAI's and Groq's lists are per account: a model that is not on the vendor's "
              "deprecation page as well is unconfirmed.", ""]
    if result["gone"]:
        lines += ["- **%s `%s`** (%s, %s)%s" % (VENDOR_NAMES[v], i, k, s, gone_note(v, i, pages["confirmed"]))
                  for v, i, k, s in result["gone"]]
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

    lines += ["## On the vendor's deprecation page", "",
              "Each catalogue model looked up in the tables of %s. Never part of the release rule: "
              "the warning to deprecate the model before its date." % ", ".join(
                  "[%s](%s)" % (VENDOR_NAMES[v], u) for v, u in sorted(DEPRECATION_PAGES.items())), ""]
    if pages["findings"]:
        lines += ["- " + page_finding_text(f) for f in pages["findings"]]
    else:
        lines.append("None.")
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

    checked = datetime.date.fromisoformat(catalogue["pricesChecked"])
    age = (today - checked).days
    lines += ["## Prices checked by hand", ""]
    if age > PRICE_RECHECK_DAYS:
        lines.append("**%d days ago (%s), more than %d: check them again** (docs/prices.md)."
                     % (age, catalogue["pricesChecked"], PRICE_RECHECK_DAYS))
    else:
        lines.append("%d days ago (%s)." % (age, catalogue["pricesChecked"]))
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
        lines += ["", "No published list (the speech-to-text guide's new lines below show whether the vendor "
                  "now publishes one): %s." % ", ".join(unpublished)]
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

    lines += ["## New lines on the vendors' pages", "",
              "Lines that were not on the page at its stored copy and that name a catalogue model "
              "(in bold) or say deprecated, shutdown, retire, sunset, speech-to-text, transcription, "
              "Scribe or Whisper. Read them: what they mean is not decided here.", ""]
    for page in pages["text"]:
        lines += text_page_lines(page)
    if not pages["text"]:
        lines.append("No page was read.")
    lines.append("")

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
    return "\n".join(lines), gate, bool(unchecked or unread)


def gone_note(vendor, model_id, confirmed):
    if (vendor, model_id) in confirmed:
        return ": on the [deprecation page](%s)" % confirmed[(vendor, model_id)]
    if vendor in ("openAI", "groq"):
        return ": not on the deprecation page, **unconfirmed** (the list is per account)"
    return ""


def page_finding_text(f):
    name = "%s `%s` (%s, %s)" % (VENDOR_NAMES[f["vendor"]], f["id"], f["kind"], f["state"])
    replacement = (", replacement %s" % " or ".join("`%s`" % r for r in f["replacement"])) if f["replacement"] else ""
    if f["type"] == "deprecation_listed":
        when = ("shuts down %s" % f["date"].isoformat()) if f["date"] else "deprecated, no date yet"
        return "**%s**: %s%s" % (name, when, replacement)
    if f["type"] == "deprecation_date_changed":
        return "**%s**: the page says %s, the catalogue %s%s" % (name, f["date"].isoformat(), f["catalogue"],
                                                                   replacement)
    return "%s: still Active, but its earliest retirement date (%s) has passed" % (name, f["date"].isoformat())


def text_page_lines(page):
    title = "[%s](%s)" % (page["slug"], page["url"])
    if "error" in page:
        return ["- %s: not read: %s" % (title, page["error"])]
    if page.get("uncompared"):
        return ["- %s: read, but not compared: without SPEECHTEXT_VENDOR_WATCH no copy is kept" % title]
    if page.get("baseline"):
        return ["- %s: stored as the baseline; its new lines show from the next run" % title]
    if not page["lines"]:
        return ["- %s: nothing new since %s" % (title, page["since"])]
    out = ["- %s, new since %s:" % (title, page["since"])]
    for entry in page["lines"][:PAGE_LINES_SHOWN]:
        text = entry["line"] if len(entry["line"]) <= 300 else entry["line"][:300] + "…"
        names = ("**%s**: " % ", ".join("`%s`" % m for m in entry["models"])) if entry["models"] else ""
        out.append("  - %s%s%s" % (names, ("%s: " % entry["section"]) if entry["section"] else "", text))
    if len(page["lines"]) > PAGE_LINES_SHOWN:
        out.append("  - … %d more" % (len(page["lines"]) - PAGE_LINES_SHOWN))
    return out


# MARK: - Findings

PER_ACCOUNT = ("openAI", "groq")


def finding(key, kind, details, vendor=None, model=None, gate=False, per_account=False, confirmed_by=None,
            source=None):
    return {"key": key, "kind": kind, "details": details, "vendor": vendor, "model": model, "gate": gate,
            "per_account": per_account, "confirmed_by": confirmed_by, "source": source}


def findings(catalogue, result, pages, new, packages, sources, repos, languages, today):
    """What the report says needs acting on, one entry per model, package or source, for
    filing issues. `key` names the thing, so a finding can be matched with the
    issue it already has; `details` is a line of Markdown."""
    out = []
    for v, i, k, s in result["gone"]:
        confirmed = pages["confirmed"].get((v, i))
        out.append(finding("%s/%s" % (v, i), "gone",
                           "%s no longer serves `%s` (%s, %s in the catalogue)." % (VENDOR_NAMES[v], i, k, s),
                           v, i, gate=True, per_account=v in PER_ACCOUNT, confirmed_by=confirmed))
    for v, i, k, d, s in result["going"]:
        out.append(finding("%s/%s" % (v, i), "shutdown_announced",
                           "%s's API announces a shutdown for `%s` (%s): %s; catalogue: %s."
                           % (VENDOR_NAMES[v], i, k, d, s), v, i))
    for v, i, k, d, r in result["expired"]:
        out.append(finding("%s/%s" % (v, i), "past_shutdown", "`%s` (%s) shut down %s; %s." % (i, k, d, r), v, i))
    for v, i, ours, theirs in result["drift"]:
        out.append(finding("%s/%s" % (v, i), "price_drift",
                           "%s `%s`: catalogue %s, API %s." % (VENDOR_NAMES[v], i, ours, theirs), v, i))
    for f in pages["findings"]:
        out.append(finding("%s/%s" % (f["vendor"], f["id"]), f["type"], page_finding_text(f) + ".",
                           f["vendor"], f["id"], source=f["url"]))
    for page in pages["text"]:
        for entry in page.get("lines", []):
            if not LIFECYCLE_WORDS.search(entry["line"]):
                continue
            for model_id in entry["models"]:
                out.append(finding("%s/%s" % (page["vendor"], model_id), "page_mention",
                                   "New on [%s](%s)%s: %s" % (page["slug"], page["url"],
                                                              " (%s)" % entry["section"] if entry["section"] else "",
                                                              entry["line"]),
                                   page["vendor"], model_id, source=page["url"]))
    for v, ids in sorted(new.items()):
        for i in ids:
            out.append(finding("%s/new/%s" % (v, i), "new_at_vendor",
                               "%s serves `%s`, which is not in the catalogue and was not served at the "
                               "previous run." % (VENDOR_NAMES[v], i), v, i))
    lists, _ = languages
    for entry in lists:
        if entry.get("added") or entry.get("dropped"):
            out.append(finding("languages/%s" % entry["source"], "language_list",
                               "%s (%s): added %s; dropped %s." % (entry["source"], ", ".join(entry["models"]),
                                                                   ", ".join(entry["added"]) or "none",
                                                                   ", ".join(entry["dropped"]) or "none"),
                               source=entry["source"]))
        elif entry.get("manual") and entry.get("stale"):
            out.append(finding("languages/%s" % entry["source"], "language_list",
                               "%s (%s): read it again by hand, checked %s." % (entry["source"],
                                                                               ", ".join(entry["models"]),
                                                                               entry["checked"]),
                               source=entry["source"]))
    for s in sources:
        if s.get("missing"):
            out.append(finding("local/%s" % s["id"], "local_model",
                               "`%s`: missing from %s: %s." % (s["id"], s["repo"], ", ".join(s["missing"])),
                               "local", s["id"], gate=True, source="https://huggingface.co/" + s["repo"]))
    for p in packages:
        if p.get("newer"):
            out.append(finding("package/%s" % p["package"], "package_release",
                               "%s: pinned %s, newer %s." % (p["package"], p["pinned"],
                                                             ", ".join(r["tag"] for r in p["newer"])),
                               source="https://github.com/%s/releases" % p["package"]))
    for r in repos:
        if r["speech"]:
            out.append(finding("huggingface/%s" % r["id"], "new_repository",
                               "New repository `%s` (%s%s)." % (r["id"], r["created"],
                                                                ", " + r["task"] if r["task"] else ""),
                               source="https://huggingface.co/" + r["id"]))
    age = (today - datetime.date.fromisoformat(catalogue["pricesChecked"])).days
    if age > PRICE_RECHECK_DAYS:
        out.append(finding("prices", "price_age",
                           "The prices were checked by hand %d days ago (%s), more than %d (docs/prices.md)."
                           % (age, catalogue["pricesChecked"], PRICE_RECHECK_DAYS)))
    return out


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
    parser.add_argument("--json", help="also write the findings as JSON, for filing issues")
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
    gone = {(v, i) for v, i, _, _ in result["gone"]}
    page_findings, confirmed, page_problems = deprecation_pages(catalogue, gone, today)
    pages = {"findings": page_findings, "confirmed": confirmed, "problems": page_problems,
             "text": text_pages(catalogue, args.snapshots, today)}
    new, absent = candidates(catalogue, served, (previous or {}).get("vendors"))
    packages = package_releases(args.resolved)
    sources = huggingface_sources(catalogue["speech"] + catalogue["chat"])
    repos, repo_errors = new_repositories(args.since)
    languages = language_lists(catalogue, today)
    text, gate, unchecked = report(args, catalogue, served, problems, result, new, absent, packages, sources,
                                   repos, repo_errors, previous_date, today, languages, pages)
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

    status = 1 if gate else (3 if unchecked else 0)
    if args.json:
        with open(args.json, "w") as out:
            json.dump({"date": today.isoformat(), "commit": args.commit, "exit": status,
                       "unchecked": sorted(problems) + ["%s deprecation page" % v for v in sorted(page_problems)],
                       "findings": findings(catalogue, result, pages, new, packages, sources, repos,
                                            languages, today)},
                      out, indent=1, sort_keys=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
