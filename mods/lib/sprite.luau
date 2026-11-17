--!strict
-- Hareketli GIF/WebP → tek sprite sheet planı. Tern CSS arka planında hareketli
-- görselin yalnız ilk karesini çizer ve bir görseli kenarı en çok 4096 px
-- olarak yükler; kareler bu sınıra sığan bir ızgaraya dizilir.

local sprite = {}

sprite.MAX_SIDE = 4096
sprite.MAX_FRAMES = 48
sprite.MAX_FPS = 12

export type Plan = {
	frames: number,
	fps: number,
	cols: number,
	rows: number,
	-- Bir karenin piksel boyu (çift sayı: ffmpeg'in jpeg kodlayıcısı ister).
	w: number,
	h: number,
}

local function even(n: number): number
	local i = math.floor(n)
	return i - i % 2
end

--- Kaynak boyu (`w`×`h`), saniye cinsinden süre ve kaynak kare hızından plan;
--- tek kareli ya da okunamayan girdi için nil.
function sprite.plan(w: number, h: number, duration: number?, src_fps: number?, src_frames: number?): Plan?
	if w <= 0 or h <= 0 then
		return nil
	end
	local fps = math.clamp(math.floor((src_fps or sprite.MAX_FPS) + 0.5), 1, sprite.MAX_FPS)
	local frames
	if duration and duration > 0 then
		frames = math.floor(duration * fps + 0.5)
	elseif src_frames then
		frames = src_frames
	else
		return nil
	end
	frames = math.min(frames, sprite.MAX_FRAMES)
	if frames < 2 then
		return nil
	end
	-- En geniş kareyi veren sütun sayısı.
	local best: Plan? = nil
	for cols = 1, frames do
		local rows = math.ceil(frames / cols)
		local fw = math.min(w, sprite.MAX_SIDE / cols, sprite.MAX_SIDE / rows * w / h)
		local fh = fw * h / w
		local pw, ph = even(fw), even(fh)
		if pw >= 2 and ph >= 2 and (best == nil or pw > best.w) then
			best = { frames = frames, fps = fps, cols = cols, rows = rows, w = pw, h = ph }
		end
	end
	return best
end

--- ffprobe'un `r_frame_rate`/`avg_frame_rate` kesri ("15/1", "100/7") → sayı.
function sprite.rate(s: any): number?
	if type(s) ~= "string" then
		return nil
	end
	local a, b = string.match(s, "^(%d+)/(%d+)$")
	if a and b and tonumber(b) ~= 0 then
		return (tonumber(a) :: number) / (tonumber(b) :: number)
	end
	return tonumber(s)
end

return sprite
