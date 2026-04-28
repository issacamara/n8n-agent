import os
import math
from datetime import datetime, timezone

import requests
import functions_framework
from twilio.rest import Client


# ── Array geometry ────────────────────────────────────────────────
LATITUDE      = 12.65   # degrees North, Mali
LONGITUDE     = -8.00
PANEL_TILT    = 17      # degrees from horizontal
PANEL_AZIMUTH = -45     # south-east = 45° east of south

# ── System capacity ───────────────────────────────────────────────
MONO_KWP     = 6.0      # 20 × 300 W monofacial panels
BIFACIAL_KWP = 6.0      # 10 × 600 W bifacial panels

# ── Performance constants ─────────────────────────────────────────
BASE_PR       = 0.85    # system performance ratio (inverter, wiring, mismatch)
TEMP_COEFF    = -0.0042 # power temp coefficient per °C
NOCT          = 45      # nominal operating cell temperature °C
REF_CELL_TEMP = 25      # STC reference temperature °C
BIFACIAL_GAIN = 1.03    # conservative rear-side gain for bifacial modules

# ── Incidence angle modifier (ASHRAE model) ───────────────────────
IAM_B0 = 0.05

# ── Installation dates ────────────────────────────────────────────
MONO_INSTALL_DATE = datetime(2023, 9, 1, tzinfo=timezone.utc)
BIF_INSTALL_DATE  = datetime(2025, 1, 1, tzinfo=timezone.utc)

# ── Annual degradation rates ──────────────────────────────────────
MONO_ANNUAL_DEG = 0.006
BIF_ANNUAL_DEG  = 0.004

# ── Energy management ─────────────────────────────────────────────
PRIORITY_LOAD_KWH = 27.5  # midpoint of 25-30 kWh/day household need
RIG_POWER_KW      = 1.1   # mining rig power consumption
DAY_HOURS         = 24.0


# -----------------------------------------------------------------
# Degradation
# -----------------------------------------------------------------

def _degradation_factor(install_date: datetime, annual_rate: float, now: datetime) -> float:
    """Compute remaining power fraction based on age and annual degradation rate."""
    years = (now - install_date).days / 365.25
    return max(0.0, 1.0 - annual_rate * years)


# -----------------------------------------------------------------
# Solar geometry
# -----------------------------------------------------------------

def _solar_declination(day_of_year: int) -> float:
    """Solar declination angle in degrees (Cooper's equation)."""
    return 23.45 * math.sin(math.radians((360 / 365) * (day_of_year - 81)))


def _angle_of_incidence(hour_of_day: int, day_of_year: int) -> float:
    """
    Angle of incidence (AOI) of direct beam radiation on the tilted panel surface.
    Returns 90 if sun is below horizon or behind panel.
    """
    lat_r  = math.radians(LATITUDE)
    tilt_r = math.radians(PANEL_TILT)
    azim_r = math.radians(PANEL_AZIMUTH)

    decl_r = math.radians(_solar_declination(day_of_year))

    lon_correction = LONGITUDE / 15.0
    solar_hour     = hour_of_day + lon_correction
    ha_r           = math.radians((solar_hour - 12.0) * 15.0)

    sin_alt = (
        math.sin(lat_r) * math.sin(decl_r)
        + math.cos(lat_r) * math.cos(decl_r) * math.cos(ha_r)
    )
    sin_alt    = max(-1.0, min(1.0, sin_alt))
    altitude_r = math.asin(sin_alt)

    if altitude_r <= 0:
        return 90.0

    cos_alt = math.cos(altitude_r)

    cos_az = (
        (math.sin(decl_r) - math.sin(lat_r) * sin_alt)
        / (math.cos(lat_r) * cos_alt + 1e-9)
    )
    cos_az     = max(-1.0, min(1.0, cos_az))
    solar_az_r = math.acos(cos_az)
    if ha_r > 0:
        solar_az_r = -solar_az_r  # afternoon: sun west of south

    cos_aoi = (
        math.sin(altitude_r) * math.cos(tilt_r)
        + math.cos(altitude_r) * math.cos(solar_az_r - azim_r) * math.sin(tilt_r)
    )
    cos_aoi = max(0.0, min(1.0, cos_aoi))
    return math.degrees(math.acos(cos_aoi))


def _iam_correction(aoi_deg: float) -> float:
    """ASHRAE incidence angle modifier: IAM = 1 - b0 * (1/cos(aoi) - 1)"""
    if aoi_deg >= 90:
        return 0.0
    cos_aoi = math.cos(math.radians(aoi_deg))
    if cos_aoi < 1e-6:
        return 0.0
    iam = 1.0 - IAM_B0 * (1.0 / cos_aoi - 1.0)
    return max(0.0, min(1.0, iam))


# -----------------------------------------------------------------
# Weather forecast
# -----------------------------------------------------------------

def _get_forecast(days: int = 2) -> dict:
    """
    Fetch hourly forecast from Open-Meteo for the panel plane.
    days=2 fetches today + tomorrow in a single API call.
    global_tilted_irradiance is projected onto the panel surface
    at the specified tilt and azimuth.
    """
    url = (
        "https://api.open-meteo.com/v1/forecast"
        f"?latitude={LATITUDE}&longitude={LONGITUDE}"
        "&hourly=global_tilted_irradiance,temperature_2m,cloud_cover,precipitation"
        f"&tilt={PANEL_TILT}&azimuth={180 + PANEL_AZIMUTH}"
        f"&forecast_days={days}"
        "&timezone=Africa%2FBamako"
    )
    resp = requests.get(url, timeout=30)
    resp.raise_for_status()
    return resp.json()


def _split_days(hourly: dict) -> tuple[dict, dict]:
    """
    Split hourly data (48 entries for 2 days) into two separate
    day-sized dicts that _compute_production can process individually.
    """
    times      = hourly["time"]
    today_date = times[0][:10]

    today_idx    = [i for i, t in enumerate(times) if t.startswith(today_date)]
    tomorrow_idx = [i for i, t in enumerate(times) if not t.startswith(today_date)]

    def _slice(idx: list) -> dict:
        return {
            "time":                     [times[i] for i in idx],
            "global_tilted_irradiance": [hourly["global_tilted_irradiance"][i] for i in idx],
            "temperature_2m":           [hourly["temperature_2m"][i] for i in idx],
            "cloud_cover":              [hourly.get("cloud_cover", [0]*len(times))[i] for i in idx],
            "precipitation":            [hourly.get("precipitation", [0]*len(times))[i] for i in idx],
        }

    return _slice(today_idx), _slice(tomorrow_idx)


# -----------------------------------------------------------------
# Production estimate
# -----------------------------------------------------------------

def _compute_production(hourly: dict) -> tuple:
    """
    Estimate daily PV production in kWh from hourly GTI forecast.

    Per hour:
      1. GTI from Open-Meteo (W/m2 on panel plane)
      2. IAM (ASHRAE) - oblique reflection losses
      3. NOCT cell temperature model - thermal derating
      4. Dynamic degradation from installation date
      5. Seasonal bifacial rear-side gain
      6. System performance ratio
    """
    times = hourly["time"]
    gti   = hourly["global_tilted_irradiance"]
    temp  = hourly["temperature_2m"]
    cloud = hourly.get("cloud_cover",   [0] * len(times))
    rain  = hourly.get("precipitation", [0] * len(times))

    now      = datetime.now(timezone.utc)
    mono_deg = _degradation_factor(MONO_INSTALL_DATE, MONO_ANNUAL_DEG, now)
    bif_deg  = _degradation_factor(BIF_INSTALL_DATE,  BIF_ANNUAL_DEG,  now)

    date_obj    = datetime.fromisoformat(times[0])
    day_of_year = date_obj.timetuple().tm_yday
    month       = date_obj.month

    # Dry season: bare soil has lower albedo -> reduced bifacial rear gain
    bifacial_seasonal = BIFACIAL_GAIN - (0.01 if month in [11, 12, 1, 2, 3] else 0.0)

    total_energy   = 0.0
    daylight_hours = 0
    cloud_sum      = 0.0
    rain_sum       = 0.0
    max_temp       = -999.0

    for i, ts in enumerate(times):
        poa = float(gti[i] or 0)
        amb = float(temp[i] or 0)
        cc  = float(cloud[i] or 0)
        rr  = float(rain[i] or 0)

        max_temp  = max(max_temp, amb)
        rain_sum += rr

        if poa < 50:
            continue

        daylight_hours += 1
        cloud_sum      += cc

        hour_of_day = datetime.fromisoformat(ts).hour

        aoi = _angle_of_incidence(hour_of_day, day_of_year)
        iam = _iam_correction(aoi)

        cell_temp   = amb + ((NOCT - 20) / 800.0) * poa
        temp_factor = 1.0 + TEMP_COEFF * (cell_temp - REF_CELL_TEMP)
        if cell_temp > 60:
            temp_factor -= 0.02
        if cell_temp > 70:
            temp_factor -= 0.02
        temp_factor = max(0.70, temp_factor)

        eff_poa = poa * iam

        mono_hour = (eff_poa / 1000.0) * MONO_KWP * BASE_PR * temp_factor * mono_deg
        bif_hour  = (eff_poa / 1000.0) * BIFACIAL_KWP * BASE_PR * temp_factor * bif_deg * bifacial_seasonal

        total_energy += mono_hour + bif_hour

    avg_cloud = round(cloud_sum / daylight_hours) if daylight_hours else 0

    return (
        round(total_energy, 1),
        avg_cloud,
        round(rain_sum, 1),
        round(max_temp, 1),
        month,
        day_of_year,
        round(mono_deg, 4),
        round(bif_deg, 4),
    )


# -----------------------------------------------------------------
# Energy management
# -----------------------------------------------------------------

def _rig_schedule(kwh: float) -> tuple:
    """
    Determine safe mining rig runtime for the day.

    1. Priority household load is covered first (27.5 kWh).
    2. Remaining energy goes to the rig at 1.1 kW.
    3. Runtime is capped at 24h.
    4. Off time = 24h - runtime.
    """
    energy_for_rig = max(0.0, kwh - PRIORITY_LOAD_KWH)
    rig_run_hours  = round(min(DAY_HOURS, energy_for_rig / RIG_POWER_KW), 1)
    rig_off_hours  = round(DAY_HOURS - rig_run_hours, 1)
    return rig_run_hours, rig_off_hours


def _sky_label(avg_cloud: float, rain: float) -> str:
    sky = "☀️ Sunny"
    if avg_cloud > 70:
        sky = "☁️ Overcast"
    elif avg_cloud > 30:
        sky = "⛅ Partly Cloudy"
    if rain > 1:
        sky += " 🌧️ Rain"
    return sky


# -----------------------------------------------------------------
# Twilio WhatsApp
# -----------------------------------------------------------------

def _send_whatsapp(body: str) -> dict:
    client = Client(
        os.environ["TWILIO_ACCOUNT_SID"],
        os.environ["TWILIO_AUTH_TOKEN"],
    )
    msg = client.messages.create(
        from_=os.environ["TWILIO_WHATSAPP_FROM"],
        to=os.environ["TWILIO_WHATSAPP_TO"],
        body=body,
    )
    return {"sid": msg.sid, "status": msg.status}


# -----------------------------------------------------------------
# Cloud Function entrypoint
# -----------------------------------------------------------------

@functions_framework.http
def solar_forecast(request):
    try:
        # Single API call fetches today + tomorrow (forecast_days=2)
        data   = _get_forecast(days=2)
        hourly = data["hourly"]

        today_hourly, tomorrow_hourly = _split_days(hourly)

        today_date    = today_hourly["time"][0][:10]
        tomorrow_date = tomorrow_hourly["time"][0][:10]

        # --- Today ---
        kwh_today, cloud_today, rain_today, temp_today, month, doy, mono_deg, bif_deg = (
            _compute_production(today_hourly)
        )
        rig_run_hours, rig_off_hours = _rig_schedule(kwh_today)
        sky_today = _sky_label(cloud_today, rain_today)

        season = (
            "🌵 Dry season"
            if month in [11, 12, 1, 2, 3, 4]
            else "🌧️ Wet season"
        )

        # --- Tomorrow ---
        kwh_tmrw, cloud_tmrw, rain_tmrw, temp_tmrw, _, _, _, _ = (
            _compute_production(tomorrow_hourly)
        )
        rig_run_tmrw, rig_off_tmrw = _rig_schedule(kwh_tmrw)
        sky_tmrw = _sky_label(cloud_tmrw, rain_tmrw)

        message = (
            f"🌞 *Solar Production Forecast — Bamako*\n\n"

            f"━━━ 📅 Today — {today_date} ━━━\n"
            f"📍 Day {doy}/365 | {season}\n"
            f"⚡ Production: *{kwh_today} kWh*\n"
            f"🏠 Priority load: {PRIORITY_LOAD_KWH} kWh\n"
            f"⛏️ Mining rig: run *{rig_run_hours}h* | off *{rig_off_hours}h*\n"
            f"🌤️ {sky_today} ({cloud_today}% cloud cover)\n"
            f"🌡️ Max temp: {temp_today}°C | 🌧️ Rain: {rain_today} mm\n\n"

            f"━━━ 🔭 Tomorrow — {tomorrow_date} ━━━\n"
            f"⚡ Production: *{kwh_tmrw} kWh*\n"
            f"⛏️ Mining rig: run *{rig_run_tmrw}h* | off *{rig_off_tmrw}h*\n"
            f"🌤️ {sky_tmrw} ({cloud_tmrw}% cloud cover)\n"
            f"🌡️ Max temp: {temp_tmrw}°C | 🌧️ Rain: {rain_tmrw} mm\n\n"

        )

        twilio_result = _send_whatsapp(message)

        return {
            "ok": True,
            "today": {
                "date":          today_date,
                "day_of_year":   doy,
                "estimated_kwh": kwh_today,
                "rig_run_hours": rig_run_hours,
                "rig_off_hours": rig_off_hours,
            },
            "tomorrow": {
                "date":          tomorrow_date,
                "estimated_kwh": kwh_tmrw,
                "rig_run_hours": rig_run_tmrw,
                "rig_off_hours": rig_off_tmrw,
            },
            "mono_deg":      mono_deg,
            "bif_deg":       bif_deg,
            "twilio_sid":    twilio_result["sid"],
            "twilio_status": twilio_result["status"],
        }, 200

    except Exception as exc:
        return {"ok": False, "error": str(exc)}, 500
