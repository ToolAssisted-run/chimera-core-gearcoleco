-- Frontend witness for the Gearcoleco package: run the core inside
-- Chimera's window for a number of frames, holding the buttons the job
-- names, then dump one memory domain. run-frontend.sh compares the dump byte
-- for byte with the native reference's (run-native --dump-domain).
--
-- The job file named by the MINIHAWK_JOB environment variable says:
--   frames=<how many frames>   domain=<the memory domain to dump>
--   system=<the system id the machine must report>
--   out=<the dump>   meta=<status and counts>   shot=<optional screenshot>
--   hold=<buttons held on every frame, comma separated>

local function writeAll(path, data)
	local f = assert(io.open(path, "wb"))
	f:write(data)
	f:close()
end

local meta = {}
local function finish(status, detail)
	local lines = {
		"status=" .. status,
		"detail=" .. (detail or ""),
		"frames=" .. (meta.frames or 0),
		"lag=" .. (meta.lag or 0),
		"ramsize=" .. (meta.ramsize or 0),
	}
	if meta.metaPath then
		writeAll(meta.metaPath, table.concat(lines, "\n") .. "\n")
	end
	client.exit()
end

local jobPath = os.getenv("MINIHAWK_JOB")
if jobPath == nil then
	error("MINIHAWK_JOB env var not set")
end
local job = {}
for line in io.lines(jobPath) do
	local k, v = line:match("^([^=]+)=(.*)$")
	if k then job[k] = v end
end
meta.metaPath = job.meta

if emu.getsystemid() ~= job.system then
	finish("ERROR", "wrong system id: " .. tostring(emu.getsystemid()))
end
if emu.getcorename() ~= "Gearcoleco" then
	finish("ERROR", "wrong core: " .. tostring(emu.getcorename()))
end

pcall(function() client.speedmode(6400) end)
pcall(function() client.invisibleemulation(true) end)

local held = {}
if job.hold ~= nil and job.hold ~= "" then
	for name in string.gmatch(job.hold, "[^,]+") do
		held[name] = true
	end
end

-- In Chimera's window the movie is what plays: a script's joypad.set reaches
-- the core only while TAStudio is recording, so turn that on before holding.
if next(held) ~= nil then
	pcall(function() tastudio.setrecording(true) end)
	if not tastudio.getrecording() then
		finish("ERROR", "TAStudio would not record, so the held buttons cannot reach the core")
	end
end

local frames = tonumber(job.frames) or 120
for _ = 1, frames do
	if next(held) ~= nil then
		joypad.set(held)
	end
	emu.frameadvance()
end

meta.frames = emu.framecount()
meta.lag = emu.lagcount()
memory.usememorydomain(job.domain)
meta.ramsize = memory.getcurrentmemorydomainsize()

if job.shot ~= nil and job.shot ~= "" then
	client.screenshot(job.shot)
end

local ram = memory.read_bytes_as_array(0, meta.ramsize, job.domain)
local chunks = {}
for i = 1, #ram do
	chunks[i] = string.char(ram[i])
end
writeAll(job.out, table.concat(chunks))

finish("OK", "")
