# chimera-core-gearcoleco: Gearcoleco in miniBox's sandbox, as a Chimera core.
#
# One build description, two flavors:
#   native (the reference, run-native, and the sandbox driver, run-wbx):
#     meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native
#   guest (core.wbx), through the cross file waterbox/setup-guest.sh writes:
#     sh waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest core.wbx
#
# The source list is Gearcoleco's libretro core's (platforms/libretro/
# Makefile.common) without libretro.cpp: the emulator and miniz, which it
# uses to read zipped games. Nothing of the desktop program (SDL, ImGui, the
# debugger's windows, the MCP server) is built. Both flavors compile the
# same waterbox/cinterface.cpp; only emulibc.h differs.
project('chimera-core-gearcoleco', ['c', 'cpp'],
  default_options: ['c_std=gnu99', 'cpp_std=c++17', 'optimization=2', 'debug=false', 'warning_level=0'])

gc = 'extern/gearcoleco'

# the submodule is unmodified upstream; the patch set is applied to its
# working tree here (once: apply-patches.sh checks a marker)
run_command(files('waterbox/apply-patches.sh'), check: true)

mb = get_option('minibox_dir')
if mb == ''
  mb_candidate = meson.current_source_dir() / '../chimera/extern/chimera-common-minibox'
  if import('fs').is_dir(mb_candidate)
    mb = mb_candidate
  else
    error('pass -Dminibox_dir=<miniBox checkout> (or keep one at ../chimera/extern/chimera-common-minibox)')
  endif
endif

defs = [
  '-DNDEBUG',
  # no disassembler, trace logger or profiler: they are the debugger's, and
  # the disassembler alone keeps a table of 8 million pointers
  '-DGEARCOLECO_DISABLE_DISASSEMBLER',
  # power-on memory from a fixed seed, not the host's clock (patches/0001)
  '-DGEARCOLECO_FIXED_RANDOM_SEED',
  '-DMINIZ_NO_TIME',
]
add_project_arguments(defs + ['-fno-strict-aliasing', '-Wfatal-errors'], language: ['c', 'cpp'])
# On aarch64 GCC fuses a multiply and an add into one instruction unless told
# not to, which rounds once where the guest (built with -ffp-contract=off)
# rounds twice. Both keep them apart; x86-64 is unchanged.
if not meson.is_cross_build() and host_machine.cpu_family() == 'aarch64'
  add_project_arguments('-ffp-contract=off', language: ['c', 'cpp'])
endif

inc = include_directories(
  'waterbox',
  gc / 'src',
  gc / 'src/audio',
  gc / 'platforms/shared/dependencies/miniz',
)

core_sources = files(
  gc / 'platforms/shared/dependencies/miniz/miniz.c',
  gc / 'src/Adam.cpp',
  gc / 'src/AdamMedia.cpp',
  gc / 'src/AdamNet.cpp',
  gc / 'src/GearcolecoCore.cpp',
  gc / 'src/Memory.cpp',
  gc / 'src/Processor.cpp',
  gc / 'src/TMS9918A.cpp',
  gc / 'src/F18A.cpp',
  gc / 'src/F18A_enhancements.cpp',
  gc / 'src/F18AGPU.cpp',
  gc / 'src/Audio.cpp',
  gc / 'src/AY8910.cpp',
  gc / 'src/Input.cpp',
  gc / 'src/Cartridge.cpp',
  gc / 'src/ColecoVisionIOPorts.cpp',
  gc / 'src/opcodes.cpp',
  gc / 'src/opcodes_cb.cpp',
  gc / 'src/opcodes_ed.cpp',
  gc / 'src/TraceLogger.cpp',
  gc / 'src/Profiler.cpp',
  gc / 'src/VgmRecorder.cpp',
  gc / 'src/audio/Blip_Buffer.cpp',
  gc / 'src/audio/Effects_Buffer.cpp',
  gc / 'src/audio/Sms_Apu.cpp',
  gc / 'src/audio/Multi_Buffer.cpp',
  'waterbox/cinterface.cpp',
)

if meson.is_cross_build()
  # ---- the guest: core.wbx --------------------------------------------------
  # miniBox's musl and libstdc++ come through the cross file; the link recipe
  # is the C++ guest kit's (cxxglue for the unwinder, pthread symbols pulled in
  # for libgcc_eh), as chimera-core-snes9x links.
  mbdir = meson.get_external_property('minibox_dir')
  mbuild = meson.get_external_property('minibox_build')
  sr = meson.get_external_property('guest_sysroot')

  executable('core', core_sources,
    name_suffix: 'wbx',
    include_directories: inc,
    link_args: [
      '-static', '-no-pie',
      '-Wl,--eh-frame-hdr', '-Wl,-O2', '-Wl,--no-relax', '-Wl,-z,stack-size=8388608',
      '-T', mbdir / 'source/guest/linkscript.T',
      '-Wl,-u,pthread_once', '-Wl,-u,pthread_cond_wait',
      '-Wl,-u,pthread_cond_broadcast', '-Wl,-u,pthread_key_create',
      mbuild / 'source/guest/cxxglue.c.o',
      mbuild / 'source/guest/emulibc.c.o',
      '-L' + sr / 'lib', '-lstdc++', '-lgcc', '-lgcc_eh', '-lc'])
else
  # ---- the native reference -------------------------------------------------
  m = meson.get_compiler('c').find_library('m', required: false)
  executable('run-native', core_sources + files('waterbox/run-native.c'),
    include_directories: [include_directories('waterbox/native-shim'), inc],
    c_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn'],
    cpp_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn'],
    dependencies: [m])

  # The host library comes from the same miniBox build folder as the C++
  # guest toolchain (meson-cpp), which is the one CI builds.
  mbhost = mb / 'build/meson-cpp/source/host'
  executable('run-wbx', files('waterbox/run-wbx.c'),
    c_args: ['-I' + mb / 'source/host'],
    link_args: [mbhost / 'libminiboxhost.so', '-Wl,-rpath,' + mbhost])
endif
