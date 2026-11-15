/* cinterface.cpp - Gearcoleco behind Chimera's guest ABI.
 *
 * Two machines from one emulator: the ColecoVision (a cartridge; the Super
 * Game Module, MegaCart, Activision and OCM boards and the F18A video chip
 * are Gearcoleco's own and need nothing here) and the Coleco ADAM (its
 * three ROMs, a cartridge, two disk drives and two data pack drives, and
 * the keyboard). The setting "machine" picks which. Everything else this
 * file does is what Gearcoleco's own libretro frontend
 * (platforms/libretro/libretro.cpp) does, in the same order, without the
 * host files: the firmware and the media are the project's mounted files,
 * read whole into memory before the first frame.
 *
 * This file compiles unchanged for the guest (miniBox's emulibc) and for
 * the native reference build (native-shim/emulibc.h). The core gate is the
 * comparison of those two.
 */
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include "gearcoleco.h"
#include "Adam.h"
#include "AdamMedia.h"
#include "Mapper.h"

/* A text a person reads is a key of languages/en.json, each of its
 * arguments after a TEXT_ARG (Chimera's docs/translations.md). */
#define TEXT_ARG "\x1f"

/* Gearcoleco's desktop build prints its log unless this is set; the gate's
 * runners keep stdout for their results. */
bool g_mcp_stdio_mode = true;

/* ---- the wire: waterbox.config's button order ---------------------------
 * 0 Reset, then each player's 20 controls (P1 at 1, P2 at 21), then, on the
 * ADAM only, Computer Reset at 41 and the keyboard's 74 keys from 42 in
 * Gearcoleco's GC_AdamKey order. A ColecoVision's list is the first 41. */
#define BTN_RESET 0
#define BTN_PAD 1
#define PAD_BUTTONS 20
#define BTN_COMPUTER_RESET (BTN_PAD + 2 * PAD_BUTTONS) /* 41 */
#define BTN_KEYS (BTN_COMPUTER_RESET + 1)            /* 42 */
#define BTN_COUNT (BTN_KEYS + GC_ADAM_KEY_COUNT)     /* 116 */
#define AXIS_COUNT 2 /* P1 Spinner, P2 Spinner: movement this frame */

static const GC_Keys kPadKeys[PAD_BUTTONS] = {
	Key_Up, Key_Down, Key_Left, Key_Right, Key_Left_Button, Key_Right_Button,
	Keypad_1, Keypad_2, Keypad_3, Keypad_4, Keypad_5, Keypad_6, Keypad_7,
	Keypad_8, Keypad_9, Keypad_0, Keypad_Asterisk, Keypad_Hash,
	Key_Purple, Key_Blue,
};

/* What the frontend says is held. Levels, set between frames. */
static uint8_t g_buttons[BTN_COUNT];
static int32_t g_axes[AXIS_COUNT];
/* What the machine was last told, for the controls that are events in
 * Gearcoleco (the resets, the ADAM's keys). It is the machine's: a
 * savestate carries it, so a key held across a load stays held. */
static uint8_t g_applied[BTN_COUNT];

static GearcolecoCore *g_core;
static int g_inited;
static int g_adam;
static char g_loadError[512];
static Cartridge::ForceConfiguration g_config;

/* The picture: Gearcoleco converts straight into Chimera's byte order
 * (B, G, R, A). The largest it draws is 512x288 (the F18A). */
static uint32_t g_video[GC_VIDEO_MAX_WIDTH * GC_VIDEO_MAX_HEIGHT];
static int g_vwidth = GC_RESOLUTION_WIDTH, g_vheight = GC_RESOLUTION_HEIGHT;
/* Turbo: the frontend's choice for the moment, not part of the machine. */
ECL_INVISIBLE static int g_render = 1;

static int16_t g_audio[GC_AUDIO_BUFFER_SIZE];
static int g_audioValues; /* int16 values, two a sample */

static int g_inputRead;
ECL_INVISIBLE static uintptr_t (*g_inputPoll)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);

static void on_input_read(void)
{
	g_inputRead = 1;
	if (g_inputPoll)
		g_inputPoll(0, 0, 0, 0, 0, 0);
}

/* ---- the mounted files -------------------------------------------------- */

static uint8_t *read_whole(const char *name, long *size)
{
	FILE *f = fopen(name, "rb");
	if (f == NULL)
		return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *buf = (uint8_t *)malloc(n > 0 ? (size_t)n : 1);
	if (buf == NULL || (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n))
	{
		fclose(f);
		free(buf);
		return NULL;
	}
	fclose(f);
	*size = n;
	return buf;
}

/* The firmware is mounted under its declaration's id (waterbox.config). */
#define FW_OS7 "colecovision.rom"
#define FW_EOS "eos.rom"
#define FW_WRITER "writer.rom"

static uint8_t *read_firmware(const char *id, long want, long *size)
{
	uint8_t *buf = read_whole(id, size);
	if (buf == NULL)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.no_firmware" TEXT_ARG "%s", id);
		return NULL;
	}
	if (*size != want)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.firmware_size" TEXT_ARG "%s" TEXT_ARG "%ld" TEXT_ARG "%ld",
			id, *size, want);
		free(buf);
		return NULL;
	}
	return buf;
}

/* The EOS ROM is 8 KiB. MAME and ColEm keep it as one 16 KiB file whose
 * first 8 KiB are that ROM; such a file is taken, its first half used,
 * only when that half's CRC32 is the one Gearcoleco expects (src/Adam.cpp;
 * the pinned dump, SHA-1 AD3C20EF...). The owner decided it (2026-11-15). */
static uint32_t crc32_of(const uint8_t *p, long n)
{
	uint32_t crc = ~0U;
	while (n-- > 0)
	{
		crc ^= *p++;
		for (int bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (0xEDB88320U & (0U - (crc & 1U)));
	}
	return ~crc;
}

static uint8_t *read_eos(long *size)
{
	uint8_t *buf = read_whole(FW_EOS, size);
	if (buf == NULL)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.no_firmware" TEXT_ARG "%s", FW_EOS);
		return NULL;
	}
	if (*size == 2L * Adam::kEOSROMSize
		&& crc32_of(buf, Adam::kEOSROMSize) == Adam::GetFirmwareMetadata(GC_ADAM_FIRMWARE_EOS)->crc)
	{
		*size = Adam::kEOSROMSize; /* the first half; the rest is never read */
		return buf;
	}
	if (*size == 2L * Adam::kEOSROMSize)
		snprintf(g_loadError, sizeof g_loadError, "error.eos_half" TEXT_ARG "%s", FW_EOS);
	else if (*size != Adam::kEOSROMSize)
		snprintf(g_loadError, sizeof g_loadError, "error.eos_size" TEXT_ARG "%s" TEXT_ARG "%ld", FW_EOS, *size);
	else
		return buf;
	free(buf);
	return NULL;
}

/* The first file of a slot, by the name the project mounted it under. */
static int slot_file(const char *slot, char *name, int namesz)
{
	return wbx_slot_count(slot) > 0 && wbx_slot_name(slot, 0, name, namesz) != NULL;
}

/* ---- settings ----------------------------------------------------------- */

static int setting_is(const char *key, const char *value, const char *dflt)
{
	char buf[64];
	snprintf(buf, sizeof buf, "%s", dflt);
	wbx_setting_str(key, buf, sizeof buf);
	return strcmp(buf, value) == 0;
}

static void read_settings(void)
{
	g_adam = setting_is("machine", "adam", "colecovision");

	g_config.region = Cartridge::CartridgeUnknownRegion;
	if (setting_is("region", "ntsc", "auto"))
		g_config.region = Cartridge::CartridgeNTSC;
	else if (setting_is("region", "pal", "auto"))
		g_config.region = Cartridge::CartridgePAL;

	g_config.type = Cartridge::CartridgeNotSupported; /* Gearcoleco's "auto" */
	if (setting_is("mapper", "standard", "auto"))
		g_config.type = Cartridge::CartridgeColecoVision;
	else if (setting_is("mapper", "megacart", "auto"))
		g_config.type = Cartridge::CartridgeMegaCart;
	else if (setting_is("mapper", "activision", "auto"))
		g_config.type = Cartridge::CartridgeActivisionCart;
	else if (setting_is("mapper", "ocm", "auto"))
		g_config.type = Cartridge::CartridgeOCM;
}

static GC_VideoChip video_chip_setting(void)
{
	if (setting_is("videoChip", "tms9918a", "auto"))
		return GC_VIDEO_CHIP_TMS9918A;
	if (setting_is("videoChip", "f18a", "auto"))
		return GC_VIDEO_CHIP_F18A;
	return GC_VIDEO_CHIP_AUTO;
}

/* What only changes the picture, set on the chip the machine ended up with. */
static void apply_picture_settings(void)
{
	Video *video = g_core->GetVideo();
	Video::Overscan overscan = Video::OverscanDisabled;
	if (setting_is("overscan", "topBottom", "none"))
		overscan = Video::OverscanTopBottom;
	else if (setting_is("overscan", "full284", "none"))
		overscan = Video::OverscanFull284;
	else if (setting_is("overscan", "full320", "none"))
		overscan = Video::OverscanFull320;
	video->SetOverscan(overscan);
	video->SetNoSpriteLimit(wbx_setting_bool("noSpriteLimit", 0) != 0);
}

/* ---- loading ------------------------------------------------------------ */

static int load_cartridge(const char *name)
{
	long size = 0;
	uint8_t *rom = read_whole(name, &size);
	if (rom == NULL)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.not_read" TEXT_ARG "%s", name);
		return 0;
	}
	int ok = g_core->LoadROMFromBuffer(rom, (int)size, &g_config, name);
	free(rom);
	if (!ok)
		snprintf(g_loadError, sizeof g_loadError, "error.rejected" TEXT_ARG "%s", name);
	return ok;
}

static const struct
{
	const char *slot;
	GC_AdamMediaSlot drive;
	GC_AdamMediaType type;
} kMedia[GC_ADAM_MEDIA_SLOT_COUNT] = {
	{ "disk1", GC_ADAM_MEDIA_DISK_1, GC_ADAM_MEDIA_DISK },
	{ "disk2", GC_ADAM_MEDIA_DISK_2, GC_ADAM_MEDIA_DISK },
	{ "datapack1", GC_ADAM_MEDIA_DATA_PACK_1, GC_ADAM_MEDIA_DATA_PACK },
	{ "datapack2", GC_ADAM_MEDIA_DATA_PACK_2, GC_ADAM_MEDIA_DATA_PACK },
};
/* The name each drive's image was mounted under: its save data goes out
 * under the same name, and that is the name it comes back in by. */
static char g_mediaName[GC_ADAM_MEDIA_SLOT_COUNT][256];

/* Battery memory: a cartridge board that keeps some (an EEPROM or SRAM)
 * starts from the project's save data when there is one. */
static int seed_savedata(void)
{
	char name[256];
	if (!slot_file("savedata", name, sizeof name))
		return 1;
	Mapper *mapper = g_core->GetMemory()->GetMapper();
	u8 *data = mapper != NULL ? mapper->GetSaveData() : NULL;
	int size = mapper != NULL ? mapper->GetSaveDataSize() : 0;
	if (data == NULL || size <= 0)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.savedata_unused" TEXT_ARG "%s", name);
		return 0;
	}
	long got = 0;
	uint8_t *buf = read_whole(name, &got);
	if (buf == NULL)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.not_read" TEXT_ARG "%s", name);
		return 0;
	}
	if (got != size)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.savedata_size" TEXT_ARG "%s" TEXT_ARG "%ld" TEXT_ARG "%d",
			name, got, size);
		free(buf);
		return 0;
	}
	memcpy(data, buf, (size_t)size);
	free(buf);
	return 1;
}

static int init_colecovision(void)
{
	long size = 0;
	uint8_t *os7 = read_firmware(FW_OS7, Adam::kOS7ROMSize, &size);
	if (os7 == NULL)
		return 0;
	int ok = g_core->GetMemory()->LoadBiosFromBuffer(os7, (int)size);
	if (ok)
		g_core->LoadAdamFirmware(GC_ADAM_FIRMWARE_OS7, os7, (int)size);
	free(os7);
	if (!ok)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.no_firmware" TEXT_ARG "%s", FW_OS7);
		return 0;
	}

	char name[256];
	if (!slot_file("cart", name, sizeof name))
	{
		snprintf(g_loadError, sizeof g_loadError, "error.no_cartridge");
		return 0;
	}
	return load_cartridge(name);
}

static int init_adam(void)
{
	long n7 = 0, ne = 0, nw = 0;
	uint8_t *os7 = read_firmware(FW_OS7, Adam::kOS7ROMSize, &n7);
	uint8_t *eos = os7 ? read_eos(&ne) : NULL;
	uint8_t *writer = eos ? read_firmware(FW_WRITER, Adam::kSmartWriterROMSize, &nw) : NULL;
	int ok = writer != NULL
		&& g_core->LoadAdamFirmware(os7, (int)n7, eos, (int)ne, writer, (int)nw)
		&& g_core->GetMemory()->LoadBiosFromBuffer(os7, (int)n7);
	free(os7);
	free(eos);
	free(writer);
	if (!ok)
	{
		if (!g_loadError[0])
			snprintf(g_loadError, sizeof g_loadError, "error.adam_firmware");
		return 0;
	}

	g_core->SetAdamRegion(g_config.region);
	g_core->UnloadContent();

	/* The order is libretro.cpp's retro_load_game_special: the cartridge,
	 * then the media, then the machine is started. */
	char name[256];
	int cartridge = slot_file("adamcart", name, sizeof name);
	if (cartridge && !load_cartridge(name))
		return 0;

	int media = 0;
	for (int i = 0; i < GC_ADAM_MEDIA_SLOT_COUNT; i++)
	{
		if (!slot_file(kMedia[i].slot, name, sizeof name))
			continue;
		long size = 0;
		uint8_t *image = read_whole(name, &size);
		if (image == NULL)
		{
			snprintf(g_loadError, sizeof g_loadError, "error.not_read" TEXT_ARG "%s", name);
			return 0;
		}
		ok = g_core->LoadAdamMediaFromBuffer(kMedia[i].drive, kMedia[i].type, image, (size_t)size, false);
		free(image);
		if (!ok)
		{
			snprintf(g_loadError, sizeof g_loadError, "error.media_rejected" TEXT_ARG "%s", name);
			return 0;
		}
		snprintf(g_mediaName[i], sizeof g_mediaName[i], "%s", name);
		media = 1;
	}

	/* A cartridge alone boots as a game; with media in a drive, or with
	 * nothing at all, the ADAM starts as a computer (SmartWriter, which
	 * boots what the drives hold). */
	if (!g_core->StartAdam(cartridge && !media ? GC_ADAM_BOOT_CARTRIDGE : GC_ADAM_BOOT_COMPUTER))
	{
		snprintf(g_loadError, sizeof g_loadError, "error.adam_firmware");
		return 0;
	}
	return 1;
}

extern "C" {

ECL_EXPORT const char *GetLoadError(void) { return g_loadError; }

ECL_EXPORT int Init(void)
{
	g_loadError[0] = 0;
	read_settings();

	g_core = new GearcolecoCore();
	g_core->Init(GC_PIXEL_BGRA8888);
	g_core->SetVideoChip(video_chip_setting());
	gearcoleco_input_read_hook = on_input_read;

	if (!(g_adam ? init_adam() : init_colecovision()))
		return 0;
	if (!seed_savedata())
		return 0;
	apply_picture_settings();

	fprintf(stderr, "[gearcoleco] %s, video chip %s, cartridge %s\n",
		g_adam ? "ADAM" : "ColecoVision",
		g_core->GetVideoChip() == GC_VIDEO_CHIP_F18A ? "F18A" : "TMS9918A",
		g_core->GetCartridge()->IsReady() ? "inserted" : "none");
	g_inited = 1;
	return 1;
}

ECL_EXPORT void SetButton(int32_t index, int32_t state)
{
	if (index >= 0 && index < BTN_COUNT)
		g_buttons[index] = state != 0;
}

ECL_EXPORT void SetAxis(int32_t index, int32_t value)
{
	if (index >= 0 && index < AXIS_COUNT)
		g_axes[index] = value;
}

static void apply_input(void)
{
	/* the resets act when pressed, not for as long as they are held */
	if (g_buttons[BTN_RESET] && !g_applied[BTN_RESET])
		g_core->ResetROMPreservingRAM(&g_config);
	g_applied[BTN_RESET] = g_buttons[BTN_RESET];
	if (g_adam)
	{
		if (g_buttons[BTN_COMPUTER_RESET] && !g_applied[BTN_COMPUTER_RESET])
			g_core->ResetAdamComputer();
		g_applied[BTN_COMPUTER_RESET] = g_buttons[BTN_COMPUTER_RESET];
	}

	/* the controllers are levels, set every frame as libretro.cpp does */
	for (int p = 0; p < 2; p++)
		for (int k = 0; k < PAD_BUTTONS; k++)
		{
			GC_Controllers c = p ? Controller_2 : Controller_1;
			if (g_buttons[BTN_PAD + p * PAD_BUTTONS + k])
				g_core->KeyPressed(c, kPadKeys[k]);
			else
				g_core->KeyReleased(c, kPadKeys[k]);
		}

	/* the spinners (the Super Action Controller's, the Expansion Module 2
	 * wheel's, the Roller Controller's): this frame's movement */
	if (g_axes[0])
		g_core->Spinner1(g_axes[0]);
	if (g_axes[1])
		g_core->Spinner2(g_axes[1]);

	/* the ADAM keyboard sends a key when it goes down (and repeats it while
	 * held, on its own clock): press and release on the edges */
	if (g_adam)
		for (int k = 0; k < GC_ADAM_KEY_COUNT; k++)
		{
			uint8_t now = g_buttons[BTN_KEYS + k];
			if (now != g_applied[BTN_KEYS + k])
			{
				if (now)
					g_core->AdamKeyPressed((GC_AdamKey)k);
				else
					g_core->AdamKeyReleased((GC_AdamKey)k);
				g_applied[BTN_KEYS + k] = now;
			}
		}
}

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	(void)packed; /* more than 64 buttons: they come through SetButton */
	if (!g_inited)
		return;
	apply_input();

	g_inputRead = 0;
	g_audioValues = 0;
	g_core->RunToVBlank((u8 *)g_video, g_audio, &g_audioValues, NULL, g_render != 0);

	if (g_render)
	{
		GC_RuntimeInfo info;
		g_core->GetRuntimeInfo(info);
		g_vwidth = info.screen_width;
		g_vheight = info.screen_height;
	}
}

/* Turbo skips the conversion of the video chip's own picture into ours,
 * and nothing else: the chip still draws every line. */
ECL_EXPORT void SetRenderingEnabled(int on) { g_render = on != 0; }

ECL_EXPORT uint32_t *GetVideoBgra(void) { return g_video; }
ECL_EXPORT int GetVideoWidth(void) { return g_vwidth; }
ECL_EXPORT int GetVideoHeight(void) { return g_vheight; }
ECL_EXPORT int16_t *GetAudio(void) { return g_audio; }
ECL_EXPORT int GetAudioSampleCount(void) { return g_audioValues / 2; }

/* 3579545 Hz over 228 cycles a line, 262 lines (NTSC) or 313 (PAL). */
static int is_pal(void)
{
	GC_RuntimeInfo info;
	if (!g_core)
		return 0;
	g_core->GetRuntimeInfo(info);
	return info.region == Region_PAL;
}
ECL_EXPORT int GetVsyncNumerator(void) { return GC_MASTER_CLOCK_NTSC; }
ECL_EXPORT int GetVsyncDenominator(void)
{
	return GC_CYCLES_PER_LINE * (is_pal() ? GC_LINES_PER_FRAME_PAL : GC_LINES_PER_FRAME_NTSC);
}

ECL_EXPORT int InputWasRead(void) { return g_inputRead; }

ECL_EXPORT void SetInputPollCallback(uint64_t fn)
{
	g_inputPoll = (uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t))(uintptr_t)fn;
}

/* ---- memory domains ------------------------------------------------------
 * The machine's RAM first (a tool opens on the first one). */
static const char *domain(int i, uint8_t **ptr, int64_t *size, int *writable)
{
	int n = 0;
	*writable = 1;
	if (g_adam)
	{
		if (i == n++) { *ptr = g_core->GetAdam()->GetMainRAM(); *size = Adam::kMainRAMSize; return "Main RAM"; }
	}
	else
	{
		if (i == n++) { *ptr = g_core->GetMemory()->GetRam(); *size = 0x400; return "Work RAM"; }
		if (i == n++) { *ptr = g_core->GetMemory()->GetSGMRam(); *size = 0x8000; return "SGM RAM"; }
	}
	if (i == n++) { *ptr = g_core->GetVideo()->GetVRAM(); *size = 0x4000; return "VRAM"; }
	Mapper *mapper = g_core->GetMemory()->GetMapper();
	if (g_core->GetCartridge()->IsReady() && mapper != NULL && mapper->GetSaveData() != NULL && mapper->GetSaveDataSize() > 0)
	{
		if (i == n++) { *ptr = mapper->GetSaveData(); *size = mapper->GetSaveDataSize(); return "Cartridge Save RAM"; }
	}
	*writable = 0;
	if (g_core->GetCartridge()->IsReady())
	{
		if (i == n++) { *ptr = g_core->GetCartridge()->GetROM(); *size = g_core->GetCartridge()->GetROMSize(); return "Cartridge ROM"; }
	}
	if (i == n++) { *ptr = g_core->GetMemory()->GetBios(); *size = 0x2000; return "BIOS"; }
	return NULL;
}

ECL_EXPORT int GetMemoryDomainCount(void)
{
	uint8_t *p;
	int64_t s;
	int w, n = 0;
	while (g_core && domain(n, &p, &s, &w) != NULL)
		n++;
	return n;
}
ECL_EXPORT const char *GetMemoryDomainName(int i)
{
	uint8_t *p;
	int64_t s;
	int w;
	return g_core ? domain(i, &p, &s, &w) : NULL;
}
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i)
{
	uint8_t *p = NULL;
	int64_t s;
	int w;
	return g_core && domain(i, &p, &s, &w) ? p : NULL;
}
ECL_EXPORT int64_t GetMemoryDomainSize(int i)
{
	uint8_t *p;
	int64_t s = 0;
	int w;
	return g_core && domain(i, &p, &s, &w) ? s : 0;
}
ECL_EXPORT int GetMemoryDomainWritable(int i)
{
	uint8_t *p;
	int64_t s;
	int w = 0;
	return g_core && domain(i, &p, &s, &w) ? w : 0;
}

/* ---- the Z80's address space, read as Gearcoleco's debugger reads it
 * (Memory::DebugRetrieve changes nothing: a MegaCart's bank switch on a
 * read does not happen). A write goes to RAM only. */
static const int64_t kBusRanges[] = { 0, 0x10000, 0, 0 };
ECL_INVISIBLE static uint8_t g_busBuf[0x10000];

static int peek(int addr) { return g_core->GetMemory()->DebugRetrieve((u16)addr); }

static void poke(int addr, uint8_t v)
{
	if (g_adam)
	{
		g_core->GetAdam()->DebugWriteMemory((u16)addr, v);
		return;
	}
	Memory *m = g_core->GetMemory();
	if (addr < 0x2000)
	{
		if (m->IsSGMLowerEnabled())
			m->GetSGMRam()[addr] = v;
	}
	else if (addr < 0x6000)
	{
		if (m->IsSGMUpperEnabled())
			m->GetSGMRam()[addr] = v;
	}
	else if (addr < 0x8000)
	{
		if (m->IsSGMUpperEnabled())
			m->GetSGMRam()[addr] = v;
		else
			m->GetRam()[addr & 0x3FF] = v;
	}
}

ECL_EXPORT int32_t GetBusCount(void) { return g_inited ? 1 : 0; }
ECL_EXPORT const char *GetBusName(int32_t bus) { return bus == 0 ? "System Bus" : ""; }
ECL_EXPORT int64_t GetBusSize(int32_t bus) { return bus == 0 ? 0x10000 : 0; }
ECL_EXPORT int32_t GetBusWritable(int32_t bus) { return bus == 0; }
ECL_EXPORT const int64_t *GetBusRanges(int32_t bus) { return bus == 0 ? kBusRanges : nullptr; }
ECL_EXPORT int32_t PeekBus(int32_t bus, int32_t addr)
{
	return bus == 0 && g_inited && addr >= 0 && addr < 0x10000 ? peek(addr) : 0;
}
ECL_EXPORT void PokeBus(int32_t bus, int32_t addr, int32_t value)
{
	if (bus == 0 && g_inited && addr >= 0 && addr < 0x10000)
		poke(addr, (uint8_t)value);
}
ECL_EXPORT const uint8_t *ReadBus(int32_t bus, int64_t addr, int32_t len)
{
	if (bus != 0 || !g_inited || addr < 0 || len < 0 || addr + len > 0x10000)
		return nullptr;
	for (int32_t i = 0; i < len; i++)
		g_busBuf[i] = (uint8_t)peek((int)(addr + i));
	return g_busBuf;
}

/* ---- the Z80's registers ------------------------------------------------ */
static const char *const kRegNames[] = {
	"A", "F", "B", "C", "D", "E", "H", "L", "IX", "IY", "SP", "PC",
	"AF'", "BC'", "DE'", "HL'", "I", "R", "IFF1", "IFF2", "IM",
};
#define REG_COUNT ((int)(sizeof kRegNames / sizeof kRegNames[0]))

ECL_EXPORT int GetRegisterCount(void) { return REG_COUNT; }
ECL_EXPORT const char *GetRegisterName(int i) { return i >= 0 && i < REG_COUNT ? kRegNames[i] : NULL; }
ECL_EXPORT int GetRegisterBits(int i)
{
	if (i < 0 || i >= REG_COUNT)
		return 0;
	if (i <= 7 || i == 16 || i == 17)
		return 8;
	if (i >= 18)
		return i == 20 ? 2 : 1;
	return 16;
}
ECL_EXPORT int64_t GetRegisterValue(int i)
{
	if (!g_core)
		return 0;
	Processor::ProcessorState *s = g_core->GetProcessor()->GetState();
	switch (i)
	{
	case 0: return s->AF->GetHigh();
	case 1: return s->AF->GetLow();
	case 2: return s->BC->GetHigh();
	case 3: return s->BC->GetLow();
	case 4: return s->DE->GetHigh();
	case 5: return s->DE->GetLow();
	case 6: return s->HL->GetHigh();
	case 7: return s->HL->GetLow();
	case 8: return s->IX->GetValue();
	case 9: return s->IY->GetValue();
	case 10: return s->SP->GetValue();
	case 11: return s->PC->GetValue();
	case 12: return s->AF2->GetValue();
	case 13: return s->BC2->GetValue();
	case 14: return s->DE2->GetValue();
	case 15: return s->HL2->GetValue();
	case 16: return *s->I;
	case 17: return *s->R;
	case 18: return *s->IFF1 ? 1 : 0;
	case 19: return *s->IFF2 ? 1 : 0;
	case 20: return *s->InterruptMode;
	default: return 0;
	}
}
ECL_EXPORT const char *GetRegisterRoles(void) { return "pc PC\nsp SP\nflags F\n"; }

/* ---- save data -----------------------------------------------------------
 * Out: the cartridge's battery memory, when its board has some, as
 * battery.sav; and on the ADAM every disk or data pack the machine wrote
 * to, under the name its image was mounted by. In: battery.sav through the
 * savedata slot; a written disk goes back in through its drive's slot. */
static const char *savedata(int32_t i, const uint8_t **buf, int64_t *size)
{
	int32_t n = 0;
	if (!g_core)
		return NULL;
	Mapper *mapper = g_core->GetMemory()->GetMapper();
	if (g_core->GetCartridge()->IsReady() && mapper != NULL && mapper->GetSaveData() != NULL && mapper->GetSaveDataSize() > 0)
	{
		if (i == n++)
		{
			*buf = mapper->GetSaveData();
			*size = mapper->GetSaveDataSize();
			return "battery.sav";
		}
	}
	if (g_adam)
		for (int d = 0; d < GC_ADAM_MEDIA_SLOT_COUNT; d++)
		{
			AdamMedia *media = g_core->GetAdamMedia(kMedia[d].drive);
			if (media == NULL || !media->IsInserted() || !media->IsDirty() || !g_mediaName[d][0])
				continue;
			if (i == n++)
			{
				*buf = media->GetData();
				*size = (int64_t)media->GetSize();
				return g_mediaName[d];
			}
		}
	return NULL;
}

ECL_EXPORT int32_t GetSaveDataFileCount(void)
{
	const uint8_t *b;
	int64_t s;
	int32_t n = 0;
	while (savedata(n, &b, &s) != NULL)
		n++;
	return n;
}
ECL_EXPORT const char *GetSaveDataFileName(int32_t i)
{
	const uint8_t *b;
	int64_t s;
	return savedata(i, &b, &s);
}
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t i)
{
	const uint8_t *b;
	int64_t s = 0;
	return savedata(i, &b, &s) ? s : 0;
}
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t i)
{
	const uint8_t *b = NULL;
	int64_t s;
	return savedata(i, &b, &s) ? b : NULL;
}

} /* extern "C" */
