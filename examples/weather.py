"""Two durable steps: scripted forecast lookup, then an actual Ornith pi call."""
from datetime import datetime, timedelta
import json
import subprocess
from urllib.parse import urlencode
from urllib.request import urlopen
from zoneinfo import ZoneInfo

from clients.python.duraflow import run

MODEL = "Ornith-1.5-35B-A3B-GGUF"


def fetch_forecast(inputs, target_date):
    context = {"location": inputs["location"], "date": target_date,
               "timezone": inputs["timezone"]}
    if "fixture" in inputs:
        return {**context, "source": "SYNTHETIC FIXTURE, not actual weather", **inputs["fixture"]}
    query = urlencode({
        "latitude": inputs["latitude"], "longitude": inputs["longitude"],
        "timezone": inputs["timezone"], "start_date": target_date, "end_date": target_date,
        "temperature_unit": "fahrenheit", "wind_speed_unit": "mph",
        "daily": "temperature_2m_min,temperature_2m_max,precipitation_probability_max,wind_speed_10m_max",
    })
    try:
        with urlopen("https://api.open-meteo.com/v1/forecast?" + query, timeout=20) as response:
            data = json.load(response)
    except (OSError, ValueError) as error:
        raise RuntimeError("Weather request failed: " + str(error)) from error
    daily = data["daily"]
    if daily["time"] != [target_date]:
        raise ValueError("Weather API did not return the requested date")
    return {**context, "source": "Open-Meteo",
            "temperature_min_f": daily["temperature_2m_min"][0],
            "temperature_max_f": daily["temperature_2m_max"][0],
            "rain_probability_percent": daily["precipitation_probability_max"][0],
            "wind_max_mph": daily["wind_speed_10m_max"][0]}


def ask_ornith(forecast):
    prompt = (
        "Suggest clothing and items to bring for this forecast in three short bullets. "
        "Give brief reasons grounded only in these figures. Do not invent an itinerary "
        "or missing data. If the source says synthetic, label this a demonstration.\n"
        + json.dumps(forecast)
    )
    # No new process group: pi stays inside the engine's workflow group so
    # handled cancellation/timeout can kill it together with this Python client.
    process = subprocess.run(
        ["pi", "--offline", "--mode", "json", "-p", "--no-session",
         "--provider", "lemonade", "--model", MODEL,
         "--no-tools", "--no-extensions", "--no-skills", "--no-context-files",
         "--no-prompt-templates", "--system-prompt", "You provide concise weather-based packing advice."],
        input=prompt, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=150,
    )
    if process.returncode:
        raise RuntimeError(f"pi exited {process.returncode}: {process.stderr[-2000:]}")
    final = None
    ended = False
    for line in process.stdout.split("\n"):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError("Invalid JSON event from pi") from error
        if event.get("type") == "message_end" and event.get("message", {}).get("role") == "assistant":
            final = event["message"]
        if event.get("type") == "agent_end":
            ended = True
    if not ended or final is None or final.get("stopReason") != "stop":
        raise RuntimeError("pi did not finish with a successful assistant response: " + str(final))
    text = "\n".join(part["text"] for part in final["content"] if part["type"] == "text").strip()
    if not text:
        raise RuntimeError("pi returned no advice")
    return {"text": text, "requested_model": MODEL, "provider": final.get("provider"),
            "reported_model": final.get("model"), "usage": final.get("usage")}


def workflow(ctx):
    # Pure calculation from persisted run metadata: midnight/retry cannot move
    # the target date. An explicit date in inputs is also supported.
    local_date = datetime.fromisoformat(ctx.created_at.replace("Z", "+00:00")).astimezone(
        ZoneInfo(ctx.inputs["timezone"])
    ).date()
    target = ctx.inputs.get("date", (local_date + timedelta(days=1)).isoformat())
    forecast = ctx.step("fetch-forecast", lambda: fetch_forecast(ctx.inputs, target))
    return ctx.step("suggest-items", lambda: ask_ornith(forecast))


if __name__ == "__main__":
    run(workflow)
