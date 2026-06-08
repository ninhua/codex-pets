DEFAULT_SCALE = 0.6
ALLOWED_SCALES = (0.5, 0.6, 0.75, 1.0, 1.25, 1.5, 2.0)


def normalize_scale(value: object, default: float = DEFAULT_SCALE) -> float:
    try:
        scale = float(value)
    except (TypeError, ValueError):
        return default

    if scale <= 0:
        return default

    return min(ALLOWED_SCALES, key=lambda allowed: abs(allowed - scale))
