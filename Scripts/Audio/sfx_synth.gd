class_name SfxSynth
extends RefCounted

## Tiny procedural sound generator: retro square-wave blips built at runtime,
## so the game ships with zero audio assets.

const MIX_RATE := 22050
const ATTACK_SECONDS := 0.005 # Short fade-in to avoid a click at the start.


## A square-wave tone sweeping from start_hz to end_hz with a punchy decay.
## noise (0..1) blends in white noise for crunchier sounds.
static func sweep(start_hz: float, end_hz: float, duration: float,
		volume := 0.25, noise := 0.0) -> AudioStreamWAV:
	var frames := int(duration * MIX_RATE)
	var data := PackedByteArray()
	data.resize(frames * 2)

	var phase := 0.0
	for i in frames:
		var t := float(i) / frames
		phase = fmod(phase + lerpf(start_hz, end_hz, t) / MIX_RATE, 1.0)
		var sample := 1.0 if phase < 0.5 else -1.0
		sample = lerpf(sample, randf_range(-1.0, 1.0), noise)
		var envelope := pow(1.0 - t, 2.0) * minf(1.0, i / (MIX_RATE * ATTACK_SECONDS))
		data.encode_s16(i * 2, int(sample * envelope * volume * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav
