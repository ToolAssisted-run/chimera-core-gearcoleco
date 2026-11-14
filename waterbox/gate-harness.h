/* gate-harness.h - the shared half of run-native.c and run-wbx.c.
 *
 * One input-and-digest loop over an abstract core interface, so the native
 * reference and the sandboxed core run exactly the same schedule and print
 * the same digests: the picture, the sound, the lag frames and every memory
 * domain. The two drivers differ only in how they reach the exports.
 *
 * The wire (waterbox.config's button order): 0 Reset; 1..20 player 1's
 * Up, Down, Left, Right, Left Button, Right Button, Key 1..9, Key 0, Key *,
 * Key #, Purple, Blue; 21..40 player 2's; then on the ADAM only, 41
 * Computer Reset and 42..115 the keyboard's keys. Axes: 0 P1 Spinner,
 * 1 P2 Spinner.
 */
#ifndef GATE_HARNESS_H
#define GATE_HARNESS_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GATE_BTN_COUNT 116
#define GATE_PAD 1
#define GATE_PAD_BUTTONS 20
#define GATE_KEYS 42
#define GATE_KEY_COUNT 74

struct gate_core
{
	int (*init)(void);
	const char *(*load_error)(void);
	void (*set_button)(int32_t index, int32_t state);
	void (*set_axis)(int32_t index, int32_t value);
	void (*frame)(void);
	const uint32_t *(*video)(int *w, int *h);
	const int16_t *(*audio)(int *n);
	int (*input_was_read)(void);
	int (*domain_count)(void);
	const char *(*domain_name)(int i);
	const uint8_t *(*domain_ptr)(int i);
	int64_t (*domain_size)(int i);
	int (*vsync_numerator)(void);
	int (*vsync_denominator)(void);
	int32_t (*savedata_count)(void);
	const char *(*savedata_name)(int32_t i);
	int64_t (*savedata_size)(int32_t i);
	const uint8_t *(*savedata_buffer)(int32_t i);
	/* optional per-frame hook (the rerecord test); may be NULL */
	void (*pre_frame)(void);
	/* turn the core's drawing on and off (the turbo test) */
	void (*set_rendering)(int on);
};

struct gate_opts
{
	long frames;
	int exercise;          /* drive player 1 with a deterministic pattern */
	int exercisePad2;      /* and player 2 with a shifted one */
	int exerciseKeys;      /* press the ADAM's keys, one at a time */
	int wiggleAxes;        /* move both spinners */
	const char *hold;      /* wire indexes held on every frame, "3,8" */
	long resetAt;          /* press Reset on this frame (-1: never) */
	long computerResetAt;  /* press Computer Reset on this frame (-1: never) */
	const char *screenshotPath;
	const char *dumpDomain;
	const char *dumpPath;
	const char *savedataDir;
	int turbo;
	long turboSettle;
};

static uint64_t gate_fnv(uint64_t h, const void *p, size_t n)
{
	const uint8_t *b = (const uint8_t *)p;
	if (!h) h = 1469598103934665603ULL;
	for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
	return h;
}

/* A deterministic pattern over one controller's 20 controls. Opposite
 * directions held together are dropped: no real controller makes them. */
static void gate_exercise_pad(long frame, uint8_t *pad)
{
	/* change every 4 frames, so a game polling once a frame sees each state */
	uint64_t x = ((uint64_t)(frame / 4)) * 6364136223846793005ULL + 1442695040888963407ULL;
	x ^= x >> 29;
	for (int k = 0; k < GATE_PAD_BUTTONS; k++)
		pad[k] = (x >> k) & 1;
	if (pad[0] && pad[1]) pad[1] = 0;
	if (pad[2] && pad[3]) pad[3] = 0;
	/* the keypad sends one key at a time on the real controller; keep one */
	int key = -1;
	for (int k = 6; k < 18; k++)
		if (pad[k]) { if (key < 0) key = k; else pad[k] = 0; }
}

static int gate_write_tga(const char *path, const uint32_t *bgra, int w, int h)
{
	FILE *f = fopen(path, "wb");
	if (!f) return 0;
	uint8_t hdr[18] = { 0 };
	hdr[2] = 2;
	hdr[12] = w & 0xff; hdr[13] = (w >> 8) & 0xff;
	hdr[14] = h & 0xff; hdr[15] = (h >> 8) & 0xff;
	hdr[16] = 32;
	hdr[17] = 0x20;
	fwrite(hdr, 1, 18, f);
	fwrite(bgra, 4, (size_t)w * h, f);
	fclose(f);
	return 1;
}

static int gate_run(const struct gate_core *c, const struct gate_opts *o)
{
	if (c->init() != 1)
	{
		fprintf(stderr, "Init failed: %s\n", c->load_error ? c->load_error() : "?");
		return 1;
	}

	uint8_t held[GATE_BTN_COUNT];
	memset(held, 0, sizeof held);
	if (o->hold)
	{
		const char *s = o->hold;
		while (*s)
		{
			long i = strtol(s, (char **)&s, 10);
			if (i >= 0 && i < GATE_BTN_COUNT) held[i] = 1;
			while (*s == ',') s++;
		}
	}

	const long frames = o->frames;
	const long tail = frames / 2;
	const long hashFrom = tail + o->turboSettle;
	uint64_t vh = 0, th = 0, ah = 0;
	long lag = 0, samples = 0;
	uint8_t buttons[GATE_BTN_COUNT];
	uint8_t prev[GATE_BTN_COUNT];
	memset(prev, 0, sizeof prev);

	for (long f = 0; f < frames; f++)
	{
		memcpy(buttons, held, sizeof buttons);
		if (o->exercise)
			gate_exercise_pad(f, &buttons[GATE_PAD]);
		if (o->exercisePad2)
			gate_exercise_pad(f + 7919, &buttons[GATE_PAD + GATE_PAD_BUTTONS]);
		if (o->exerciseKeys && (f % 8) < 3 && f >= 60)
		{
			/* one key down for three frames in every eight, walking the
			 * letters, digits and Return (the first 37 keys, then 48) */
			long n = (f / 8) % 38;
			buttons[GATE_KEYS + (n == 37 ? 48 : n)] = 1;
		}
		if (f == o->resetAt) buttons[0] = 1;
		if (f == o->computerResetAt) buttons[41] = 1;

		if (o->wiggleAxes)
		{
			uint64_t w = (uint64_t)f * 2862933555777941757ULL + 3037000493ULL;
			w ^= w >> 29;
			c->set_axis(0, (int32_t)(w % 9) - 4);
			c->set_axis(1, (int32_t)((w >> 8) % 9) - 4);
		}

		if (o->turbo)
			c->set_rendering(f >= tail);

		if (c->pre_frame)
			c->pre_frame();

		for (int i = 0; i < GATE_BTN_COUNT; i++)
		{
			if (buttons[i] != prev[i])
				c->set_button(i, buttons[i]);
			prev[i] = buttons[i];
		}

		c->frame();

		int w = 0, h = 0, n = 0;
		const uint32_t *video = c->video(&w, &h);
		const int16_t *audio = c->audio(&n);
		vh = gate_fnv(vh, &w, sizeof w);
		vh = gate_fnv(vh, &h, sizeof h);
		vh = gate_fnv(vh, video, (size_t)w * h * 4);
		if (f >= hashFrom)
		{
			th = gate_fnv(th, &w, sizeof w);
			th = gate_fnv(th, &h, sizeof h);
			th = gate_fnv(th, video, (size_t)w * h * 4);
		}
		ah = gate_fnv(ah, &n, sizeof n);
		ah = gate_fnv(ah, audio, (size_t)n * 2 * sizeof(int16_t));
		samples += n;
		if (!c->input_was_read())
			lag++;

		if (o->screenshotPath && f == frames - 1)
			gate_write_tga(o->screenshotPath, video, w, h);
	}

	printf("frames=%ld\n", frames);
	printf("vsync=%d/%d\n", c->vsync_numerator(), c->vsync_denominator());
	printf("videoHash=%016llx\n", (unsigned long long)vh);
	printf("tailVideoHash=%016llx\n", (unsigned long long)th);
	printf("audioHash=%016llx\n", (unsigned long long)ah);
	printf("audioSamples=%ld\n", samples);
	printf("lagFrames=%ld\n", lag);
	int nd = c->domain_count();
	for (int i = 0; i < nd; i++)
	{
		uint64_t dh = gate_fnv(0, c->domain_ptr(i), (size_t)c->domain_size(i));
		printf("domain[%s]=%016llx\n", c->domain_name(i), (unsigned long long)dh);
	}
	if (o->savedataDir)
	{
		int32_t count = c->savedata_count();
		printf("savedataFiles=%d\n", count);
		for (int32_t i = 0; i < count; i++)
		{
			char path[4096];
			snprintf(path, sizeof path, "%s/%s", o->savedataDir, c->savedata_name(i));
			FILE *f = fopen(path, "wb");
			if (!f) { perror(path); return 1; }
			fwrite(c->savedata_buffer(i), 1, (size_t)c->savedata_size(i), f);
			fclose(f);
		}
	}
	if (o->dumpDomain && o->dumpPath)
	{
		for (int i = 0; i < nd; i++)
		{
			if (strcmp(c->domain_name(i), o->dumpDomain) != 0)
				continue;
			FILE *f = fopen(o->dumpPath, "wb");
			if (!f) { perror(o->dumpPath); return 1; }
			fwrite(c->domain_ptr(i), 1, (size_t)c->domain_size(i), f);
			fclose(f);
			return 0;
		}
		fprintf(stderr, "no such domain to dump: %s\n", o->dumpDomain);
		return 1;
	}
	return 0;
}

static int gate_parse_opts(int argc, char **argv, int first, struct gate_opts *o)
{
	memset(o, 0, sizeof *o);
	o->frames = 600;
	o->resetAt = -1;
	o->computerResetAt = -1;
	for (int i = first; i < argc; i++)
	{
		if (!strcmp(argv[i], "--frames") && i + 1 < argc) o->frames = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--exercise")) o->exercise = 1;
		else if (!strcmp(argv[i], "--exercise-pad2")) o->exercisePad2 = 1;
		else if (!strcmp(argv[i], "--exercise-keys")) o->exerciseKeys = 1;
		else if (!strcmp(argv[i], "--wiggle-axes")) o->wiggleAxes = 1;
		else if (!strcmp(argv[i], "--hold") && i + 1 < argc) o->hold = argv[++i];
		else if (!strcmp(argv[i], "--reset-at") && i + 1 < argc) o->resetAt = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--computer-reset-at") && i + 1 < argc) o->computerResetAt = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--screenshot") && i + 1 < argc) o->screenshotPath = argv[++i];
		else if (!strcmp(argv[i], "--dump-domain") && i + 2 < argc) { o->dumpDomain = argv[++i]; o->dumpPath = argv[++i]; }
		else if (!strcmp(argv[i], "--savedata-out") && i + 1 < argc) o->savedataDir = argv[++i];
		else if (!strcmp(argv[i], "--turbo")) o->turbo = 1;
		else if (!strcmp(argv[i], "--turbo-settle") && i + 1 < argc) o->turboSettle = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--rerecord")) ; /* run-wbx's */
		else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 0; }
	}
	return 1;
}

#endif /* GATE_HARNESS_H */
