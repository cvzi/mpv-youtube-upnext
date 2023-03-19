-- youtube-upnext.lua
--
-- Fetch upnext/recommended videos from youtube
-- This is forked/based on https://github.com/jgreco/mpv-youtube-quality
--
-- Diplays a menu that lets you load the upnext/recommended video from youtube
-- that appear on the right side on the youtube website.
-- If auto_add is set to true (default), the 'up next' video is automatically
-- appended to the current playlist
--
-- Bound to ctrl-u by default.
--
-- Requires curl/curl.exe or wget/wget.exe in PATH. On Windows with wget you may need
-- to set check_certificate to false, otherwise wget.exe might not be able to
-- download the youtube website.

local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local assdraw = require "mp.assdraw"

local opts = {
    --key bindings
    toggle_menu_binding = "ctrl+u",
    up_binding = "UP",
    down_binding = "DOWN",
    select_binding = "ENTER",
    append_binding = "SPACE",
    close_binding = "ESC",

    --auto fetch recommended videos when opening a url
    fetch_on_start = true,

    --auto load and add the "upnext" video to the playlist
    auto_add = true,

    --formatting / cursors
    cursor_selected = "● ",
    cursor_unselected = "○ ",
    cursor_appended = "▷ ",
    cursor_appended_selected = "▶ ",

    --font size scales by window, if false requires larger font and padding sizes
    scale_playlist_by_window = false,

    --playlist ass style overrides inside curly brackets, \keyvalue is one field, extra \ for escape in lua
    --example {\\fnUbuntu\\fs10\\b0\\bord1} equals: font=Ubuntu, size=10, bold=no, border=1
    --read http://docs.aegisub.org/3.2/ASS_Tags/ for reference of tags
    --undeclared tags will use default osd settings
    --these styles will be used for the whole playlist. More specific styling will need to be hacked in
    --
    --(a monospaced font is recommended but not required e.g. {\\fnmonospace\\fs25} )
    style_ass_tags = "",

    --paddings for top left corner
    text_padding_x = 5,
    text_padding_y = 5,

    menu_timeout = 10,

    --Screen dim when menu is open 0.0 - 1.0 (0 is no dim, 1 is black)
    curtain_opacity = 0.7,

    youtube_url = "https://www.youtube.com/watch?v=%s",

    -- Fallback Invidious instance, see https://instances.invidio.us/ for alternatives e.g. https://invidious.snopyta.org
    invidious_instance = "https://inv.riverside.rocks",

    -- Keep the width of the window the same when the next video is played
    restore_window_width = false,

    -- On Windows wget.exe may not be able to check SSL certificates for HTTPS, so you can disable checking here
    check_certificate = true,

    -- Use a cookies file
    -- (Same as youtube-dl --cookies or curl -b or wget --load-cookies)
    -- If you don't set this, the script will try to create a temporary cookies file for you
    -- On Windows you need to use a double blackslash or a single fordwardslash
    -- For example "C:\\Users\\Username\\cookies.txt"
    -- Or "C:/Users/Username/cookies.txt"
    -- Alternatively you can set this from the command line with --ytdl-raw-options=cookies=file.txt
    cookies = "",

    -- When a video is selected from the menu, the new video can be appended to the playlist
    -- or the playlist can be cleared and replaced with only the selected video.
    -- If true, the video will be appended to the playlist. If false, the playlist will be cleared.
    keep_playlist_on_select = true,

    -- What should happen if a video recommendation in uosc menu is clicked? Options are:
    -- 'submenu'  -- show a submenu with play/upnext/append option
    -- 'append'   -- append the video to the playlist
    -- 'insert'   -- play the video after the current video
    -- 'play'     -- append the video to the playlist and play it
    -- 'replace'  -- play the video and clear the playlist
    uosc_entry_action = "submenu",

    -- Should the uosc menu stay open after clicking a video recommendation
    uosc_keep_menu_open = false
}
(require "mp.options").read_options(opts, "youtube-upnext")

-- Command line options
if opts.cookies == nil or opts.cookies == "" then
    local raw_options = mp.get_property_native("options/ytdl-raw-options")
    for param, arg in pairs(raw_options) do
        if (param == "cookies") and (arg ~= "") then
            opts.cookies = arg
        end
    end
end

local script_name = mp.get_script_name()

local destroyer = nil
local upnext_cache = {}
local prefered_win_width = nil
local last_dheight = nil
local last_dwidth = nil
local watched_ids = {}
local appended_to_playlist = {}

local function table_size(t)
    local s = 0
    for _, _ in ipairs(t) do
        s = s + 1
    end
    return s
end

local function exec(args, capture_stdout, capture_stderr)
    local ret =
        mp.command_native(
        {
            name = "subprocess",
            playback_only = false,
            capture_stdout = capture_stdout,
            capture_stderr = capture_stderr,
            args = args
        }
    )
    return ret.status, ret.stdout, ret.stderr, ret
end

local function url_encode(s)
    local function repl(x)
        return string.format("%%%02X", string.byte(x))
    end

    return string.gsub(s, "([^0-9a-zA-Z!'()*._~-])", repl)
end

local function extract_videoid(url)
    local video_id = nil
    if string.find(url, "youtu") ~= nil then
        -- extract vidoe id from https://www.youtube.com/watch?v=abcd_1234-ef
        local s, e = string.find(url, "v=[^#?!&]+")
        if s ~= nil then
            video_id = string.sub(url, s + 2, e)
        else
            -- extract from https://youtu.be/abcd_1234-ef
            local s2, e2 = string.find(url, "youtu.be/[^#?!&]+")
            if s2 ~= nil then
                video_id = string.sub(url, s2 + 9, e2)
            end
        end
    end
    return video_id
end

local function download_upnext(url, post_data)
    if opts.fetch_on_start or opts.auto_add then
        msg.info("fetching 'up next' with curl...")
    else
        mp.osd_message("fetching 'up next' with curl...", 60)
    end

    local command = {"curl", "--silent", "--location"}
    if post_data then
        table.insert(command, "--request")
        table.insert(command, "POST")
        table.insert(command, "--data")
        table.insert(command, post_data)
    end
    if opts.cookies == nil or opts.cookies == "" then
        table.insert(command, "--cookie-jar")
        table.insert(command, opts.cookies)
        table.insert(command, "--cookie")
        table.insert(command, opts.cookies)
    end
    table.insert(command, url)

    local es, s, _, _ = exec(command, true)

    if (es ~= 0) or (s == nil) or (s == "") then
        if es == -1 or es == -3 or es == 127 or es == 9009 then
            -- MP_SUBPROCESS_EINIT is -3 which can mean the command was not found:
            -- https://github.com/mpv-player/mpv/blob/24dcb5d167ba9580119e0b9cc26f79b1d155fcdc/osdep/subprocess-posix.c#L335-L336
            msg.debug("curl not found, trying wget")
            local command_wget = {"wget", "-q", "-O", "-"}
            if not opts.check_certificate then
                table.insert(command_wget, "--no-check-certificate")
            end
            if post_data then
                table.insert(command_wget, "--post-data")
                table.insert(command_wget, post_data)
            end
            if opts.cookies then
                table.insert(command_wget, "--load-cookies")
                table.insert(command_wget, opts.cookies)
                table.insert(command_wget, "--save-cookies")
                table.insert(command_wget, opts.cookies)
                table.insert(command_wget, "--keep-session-cookies")
            end
            table.insert(command_wget, url)
            es, s, _, _ = exec(command, true)
            if (es ~= 0) or (s == nil) or (s == "") then
                mp.osd_message("upnext failed: curl was not found, wget failed", 10)
                return "{}"
            end
        else
            mp.osd_message("upnext failed: error=" .. tostring(es), 10)
            msg.error("failed to get upnext list: error=" .. tostring(es))
            msg.error("s: " .. tostring(s))
            msg.debug("exec (async): " .. table.concat(command, " "))
            return "{}"
        end
    end

    local consent_pos = s:find('action="https://consent.youtube.com/s"')
    if consent_pos ~= nil then
        -- Accept cookie consent form
        msg.debug("Need to accept cookie consent form")
        s = s:sub(s:find(">", consent_pos + 1, true), s:find("</form", consent_pos + 1, true))

        local post_str = ""
        for k, v in string.gmatch(s, 'name="([^"]+)" value="([^"]*)"') do
            msg.debug("name=" .. tostring(k) .. " value=" .. tostring(v))
            post_str = post_str .. url_encode(k) .. "=" .. url_encode(v) .. "&"
        end
        msg.debug("post-data=" .. tostring(post_str))
        if opts.cookies == nil or opts.cookies == "" then
            local temp_dir = os.getenv("TEMP")
            if temp_dir == nil or temp_dir == "" then
                temp_dir = os.getenv("XDG_RUNTIME_DIR")
            end
            if temp_dir == nil or temp_dir == "" then
                opts.cookies = os.tmpname()
            else
                opts.cookies = temp_dir .. "/youtube-upnext.cookies"
            end
            msg.warn(
                'Created a cookies jar file at "' ..
                    tostring(opts.cookies) .. '". To hide this warning, set a cookies file in the script configuration'
            )
        end
        return download_upnext("https://consent.youtube.com/s", post_str)
    end

    local pos1 = string.find(s, "ytInitialData =", 1, true)
    if pos1 == nil then
        mp.osd_message("upnext failed, no upnext data found err01", 10)
        msg.error("failed to find json position 01: pos1=nil")
        return "{}"
    end
    local pos2 = string.find(s, ";%s*</script>", pos1 + 1)
    if pos2 ~= nil then
        s = string.sub(s, pos1 + 15, pos2 - 1)
        return s
    else
        msg.error("failed to find json position 02")
    end

    mp.osd_message("upnext failed, no upnext data found err03", 10)
    msg.error("failed to get upnext data: pos1=" .. tostring(pos1) .. " pos2=" .. tostring(pos2))
    return "{}"
end

local function get_invidious(url)
    -- convert to invidious API call
    url = string.gsub(url, "https://youtube%.com/watch%?v=", opts.invidious_instance .. "/api/v1/videos/")
    url = string.gsub(url, "https://www%.youtube%.com/watch%?v=", opts.invidious_instance .. "/api/v1/videos/")
    url = string.gsub(url, "https://youtu%.be/", opts.invidious_instance .. "/api/v1/videos/")
    msg.debug("Invidious url:" .. url)

    local command = {"curl", "--silent", "--location"}
    if not opts.check_certificate then
        table.insert(command, "--no-check-certificate")
    end
    table.insert(command, url)

    local es, s, _, _ = exec(command, true)

    if (es ~= 0) or (s == nil) or (s == "") then
        if es == -1 or es == -3 or es == 127 or es == 9009 then
            msg.debug("curl not found, trying wget")
            local command_wget = {"wget", "-q", "-O", "-"}
            if not opts.check_certificate then
                table.insert(command_wget, "--no-check-certificate")
            end
            table.insert(command_wget, url)
            es, s, _, _ = exec(command_wget, true)
            if (es ~= 0) or (s == nil) or (s == "") then
                mp.osd_message("upnext failed: curl was not found, wget failed", 10)
                return {}
            end
        else
            mp.osd_message("upnext failed: error=" .. tostring(es), 10)
            msg.error("failed to get invidious: error=" .. tostring(es))
            return {}
        end

    end

    local data, err = utils.parse_json(s)
    if data == nil then
        mp.osd_message("upnext fetch failed (Invidious): JSON decode failed", 10)
        msg.error("parse_json failed (Invidious): " .. err)
        return {}
    end

    if data.recommendedVideos then
        local res = {}
        msg.verbose("downloaded and decoded json successfully (Invidious)")
        for i, v in ipairs(data.recommendedVideos) do
            table.insert(
                res,
                {
                    index = i,
                    label = v.title .. " - " .. v.author,
                    file = string.format(opts.youtube_url, v.videoId)
                }
            )
        end
        mp.osd_message("upnext fetch from Invidious succeeded", 10)
        return res
    elseif data.error then
        mp.osd_message("upnext fetch failed (Invidious): " .. data.error, 10)
        msg.error("Invidious error: " .. data.error)
    else
        mp.osd_message("upnext: No recommended videos! (Invidious)", 10)
        msg.error("No recommended videos! (Invidious)")
    end

    return {}
end

local function parse_upnext(json_str, current_video_url)
    if json_str == "{}" then
        return {}, 0
    end

    local data, err = utils.parse_json(json_str)

    if data == nil then
        mp.osd_message("upnext failed: JSON decode failed", 10)
        msg.error("parse_json failed: " .. tostring(err))
        msg.debug("Corrupted JSON:\n" .. json_str .. "\n")
        return {}, 0
    end

    local skipped_results = {}
    local res = {}
    msg.verbose("downloaded and decoded json successfully")

    local index = 1
    local autoplay_id = nil
    if
        data.playerOverlays and data.playerOverlays.playerOverlayRenderer and
            data.playerOverlays.playerOverlayRenderer.autoplay and
            data.playerOverlays.playerOverlayRenderer.autoplay.playerOverlayAutoplayRenderer
     then
        local title =
            data.playerOverlays.playerOverlayRenderer.autoplay.playerOverlayAutoplayRenderer.videoTitle.simpleText
        local video_id = data.playerOverlays.playerOverlayRenderer.autoplay.playerOverlayAutoplayRenderer.videoId
        if watched_ids[video_id] == nil then -- Skip if the video was already watched
            autoplay_id = video_id
            table.insert(
                res,
                {
                    index = index,
                    label = title,
                    file = string.format(opts.youtube_url, video_id)
                }
            )
            index = index + 1
        else
            table.insert(
                skipped_results,
                {
                    index = index,
                    label = title,
                    file = string.format(opts.youtube_url, video_id)
                }
            )
            index = index + 1
        end
    end

    if
        data.playerOverlays and data.playerOverlays.playerOverlayRenderer and
            data.playerOverlays.playerOverlayRenderer.endScreen and
            data.playerOverlays.playerOverlayRenderer.endScreen.watchNextEndScreenRenderer and
            data.playerOverlays.playerOverlayRenderer.endScreen.watchNextEndScreenRenderer.results
     then
        local n = table_size(data.playerOverlays.playerOverlayRenderer.endScreen.watchNextEndScreenRenderer.results)
        for i, v in ipairs(data.playerOverlays.playerOverlayRenderer.endScreen.watchNextEndScreenRenderer.results) do
            if v.endScreenVideoRenderer and v.endScreenVideoRenderer.title and v.endScreenVideoRenderer.title.simpleText then
                local title = v.endScreenVideoRenderer.title.simpleText
                local video_id = v.endScreenVideoRenderer.videoId

                if video_id ~= autoplay_id and watched_ids[video_id] == nil then
                    table.insert(
                        res,
                        {
                            index = index + i,
                            label = title,
                            file = string.format(opts.youtube_url, video_id)
                        }
                    )
                elseif watched_ids[video_id] ~= nil then
                    table.insert(
                        skipped_results,
                        {
                            index = index + i,
                            label = title,
                            file = string.format(opts.youtube_url, video_id)
                        }
                    )
                end
            end
        end
        index = index + n
    end

    if
        data.contents and data.contents.twoColumnWatchNextResults and
            data.contents.twoColumnWatchNextResults.secondaryResults
     then
        local secondaryResults = data.contents.twoColumnWatchNextResults.secondaryResults
        if secondaryResults.secondaryResults then
            secondaryResults = secondaryResults.secondaryResults
        end
        for i, v in ipairs(secondaryResults.results) do
            local compactVideoRenderer = nil
            local watchnextindex = index
            if
                v.compactAutoplayRenderer and v.compactAutoplayRenderer and v.compactAutoplayRenderer.contents and
                    v.compactAutoplayRenderer.contents.compactVideoRenderer
             then
                compactVideoRenderer = v.compactAutoplayRenderer.contents.compactVideoRenderer
                watchnextindex = 0
            elseif v.compactVideoRenderer then
                compactVideoRenderer = v.compactVideoRenderer
            end
            if
                compactVideoRenderer and compactVideoRenderer.videoId and compactVideoRenderer.title and
                    compactVideoRenderer.title.simpleText
             then
                local title = compactVideoRenderer.title.simpleText
                local video_id = compactVideoRenderer.videoId
                local video_url = string.format(opts.youtube_url, video_id)
                local duplicate = false

                for _, entry in ipairs(res) do
                    if video_url == entry.file then
                        duplicate = true
                    end
                end
                if watched_ids[video_id] ~= nil then
                    if not duplicate then
                        table.insert(
                            skipped_results,
                            {
                                index = watchnextindex + i,
                                label = title,
                                file = video_url
                            }
                        )
                    end

                    duplicate = true
                end

                if not duplicate then
                    table.insert(
                        res,
                        {
                            index = watchnextindex + i,
                            label = title,
                            file = video_url
                        }
                    )
                end
            end
        end
    end

    -- all results where already watched, reset watched videos and use skipped_results
    if table_size(res) == 0 and table_size(skipped_results) > 0 then
        msg.debug("All upnext videos are already watched. Watched video list will be reset!")
        res = skipped_results
        watched_ids = {}
    end

    table.sort(
        res,
        function(a, b)
            return a.index < b.index
        end
    )

    upnext_cache[current_video_url] = res
    return res, table_size(res)
end

local function load_upnext()
    local url = mp.get_property("path")
    if url == nil then
        url = ""
    end

    url = string.gsub(url, "ytdl://", "") -- Strip possible ytdl:// prefix.
    url = string.gsub(url, "/shorts/", "/watch?v=") -- Convert shorts to watch?v=.
    url = string.gsub(url, "//.*/watch%?v=", "//youtube.com/watch?v=") -- Account for alternative frontends.
    url = string.gsub(url, "%?feature=share", "") -- Strip possible ?feature=share suffix.

    if string.find(url, "//youtu.be/") == nil and string.find(url, "//youtube.com/") == nil then
        -- SVP calls mpv like this:
        -- mpv '--player-operation-mode=pseudo-gui'
        -- '--input-ipc-server=mpvpipe' '--no-ytdl' '--audio-file=https://rr3---sn-4g5ednsd.googlevideo.com/videopl....'
        -- '--force-media-title=Dog Years'
        -- '--http-header-fields=Referer: https://www.youtube.com/watch?v=AbCdEf_Gh,User-Agent: Mozilla/5.0 ...'
        -- 'https://rr3---sn-4g5ednsd.googlevideo.com/videoplaybac....'
        -- We can extract the url from the header field:
        local headers = mp.get_property("http-header-fields")
        if headers ~= nil then
            local i = headers:find("Referer: ")
            if i ~= nil then
                i = i + #"Referer: "
                local j = headers:find(",", i + 15)
                if j ~= nil then
                    url = headers:sub(i, j - 1)
                end
            end
        end

        if string.find(url, "//youtu.be/") == nil and string.find(url, "//youtube.com/") == nil then
            -- Neither path nor Referer are a youtube link
            return {}, 0
        else
            -- Disable the '--no-ytdl' option from SVP
            mp.set_property_bool("no-ytdl", false)
            mp.set_property_bool("ytdl", true)
            mp.set_property_bool("autoload-files", false)
        end
    end

    -- don't fetch the website if it's already cached
    if upnext_cache[url] ~= nil then
        local res = upnext_cache[url]
        return res, table_size(res)
    end

    local res, n = parse_upnext(download_upnext(url, nil), url)

    -- Fallback to Invidious API
    if n == 0 and opts.invidious_instance and opts.invidious_instance ~= "" then
        res = get_invidious(url)
        n = table_size(res)
    end

    return res, n
end

local function add_to_playlist(path, title, flag)
    local playlist = "memory://#EXTM3U\n#EXTINF:0," .. title .. "\n" .. path
    mp.commandv("loadlist", playlist, flag)
end

local function on_file_start(_)
    local url = mp.get_property("path")

    url = string.gsub(url, "ytdl://", "") -- Strip possible ytdl:// prefix.
    url = string.gsub(url, "/shorts/", "/watch?v=") -- Convert shorts to watch?v=.
    url = string.gsub(url, "//.*/watch%?v=", "//youtube.com/watch?v=") -- Account for alternative frontends.
    url = string.gsub(url, "%?feature=share", "") -- Strip possible ?feature=share suffix.

    if string.find(url, "youtu") ~= nil then
        -- Try to add current video ID to watched list
        -- extract from https://www.youtube.com/watch?v=abcd_1234-ef
        local video_id = extract_videoid(url)

        if video_id ~= nil then
            watched_ids[video_id] = true
            msg.debug("Adding to watched_ids: " .. tostring(video_id))
        end

        local upnext, num_upnext = load_upnext()
        if num_upnext > 0 then
            add_to_playlist(upnext[1].file, upnext[1].label, "append")
            appended_to_playlist[upnext[1].file] = true
        end
    end
end

local function show_menu()
    local upnext, num_upnext = load_upnext()
    if num_upnext == 0 then
        return
    end
    mp.osd_message("", 1)

    local timeout
    local selected = 1
    local function choose_prefix(i, already_appended)
        if i == selected and already_appended then
            return opts.cursor_appended_selected
        elseif i == selected then
            return opts.cursor_selected
        end

        if i ~= selected and already_appended then
            return opts.cursor_appended
        elseif i ~= selected then
            return opts.cursor_unselected
        end

        return "> " --shouldn't get here
    end

    local function draw_menu()
        local ass = assdraw.ass_new()

        local w, h = mp.get_osd_size()

        if opts.curtain_opacity ~= nil and opts.curtain_opacity ~= 0 and opts.curtain_opacity < 1.0 then
            -- From https://github.com/christoph-heinrich/mpv-quality-menu/blob/501794bfbef468ee6a61e54fc8821fe5cd72c4ed/quality-menu.lua#L699-L707
            local alpha = 255 - math.ceil(255 * opts.curtain_opacity)
            ass.text = string.format("{\\pos(0,0)\\rDefault\\an7\\1c&H000000&\\alpha&H%X&}", alpha)
            ass:draw_start()
            ass:rect_cw(0, 0, w, h)
            ass:draw_stop()
            ass:new_event()
        end

        ass:pos(opts.text_padding_x, opts.text_padding_y)
        ass:append(opts.style_ass_tags)

        for i, v in ipairs(upnext) do
            if v ~= nil then
                ass:append(choose_prefix(i, appended_to_playlist[v.file] ~= nil) .. v.label .. "\\N")
            end
        end

        if opts.scale_playlist_by_window then
            w, h = 0, 0
        end
        mp.set_osd_ass(w, h, ass.text)
    end

    local function update_dimensions()
        draw_menu()
    end

    update_dimensions()
    mp.observe_property("osd-dimensions", "native", update_dimensions)

    local function selected_move(amt)
        selected = selected + amt
        if selected < 1 then
            selected = num_upnext
        elseif selected > num_upnext then
            selected = 1
        end
        timeout:kill()
        timeout:resume()
        draw_menu()
    end

    local function destroy()
        timeout:kill()
        mp.set_osd_ass(0, 0, "")
        mp.remove_key_binding("move_up")
        mp.remove_key_binding("move_down")
        mp.remove_key_binding("select")
        mp.remove_key_binding("append")
        mp.remove_key_binding("escape")
        mp.remove_key_binding("quit")
        mp.unobserve_property(update_dimensions)
        destroyer = nil
    end

    timeout = mp.add_periodic_timer(opts.menu_timeout, destroy)
    destroyer = destroy

    mp.add_forced_key_binding(
        opts.up_binding,
        "move_up",
        function()
            selected_move(-1)
        end,
        {repeatable = true}
    )
    mp.add_forced_key_binding(
        opts.down_binding,
        "move_down",
        function()
            selected_move(1)
        end,
        {repeatable = true}
    )
    mp.add_forced_key_binding(
        opts.select_binding,
        "select",
        function()
            destroy()
            if opts.keep_playlist_on_select then
                add_to_playlist(upnext[selected].file, upnext[selected].label, "append-play")
                local playlist_index_current = tonumber(mp.get_property("playlist-current-pos", "1"))
                local playlist_index_newfile = tonumber(mp.get_property("playlist-count", "1")) - 1
                mp.commandv("playlist-move", playlist_index_newfile, playlist_index_current + 1)
                mp.commandv("playlist-play-index", playlist_index_current + 1)
                appended_to_playlist[upnext[selected].file] = true
            else
                add_to_playlist(upnext[selected].file, upnext[selected].label, "replace")
            end
        end
    )
    mp.add_forced_key_binding(
        opts.append_binding,
        "append",
        function()
            -- prevent appending the same video twice
            if appended_to_playlist[upnext[selected].file] == true then
                timeout:kill()
                timeout:resume()
                return
            else
                add_to_playlist(upnext[selected].file, upnext[selected].label, "append")
                appended_to_playlist[upnext[selected].file] = true
                selected_move(1)
            end
        end,
        {repeatable = true}
    )
    mp.add_forced_key_binding(opts.close_binding, "quit", destroy)
    mp.add_forced_key_binding(opts.toggle_menu_binding, "escape", destroy)

    draw_menu()
    return
end

local function on_window_scale_changed(_, value)
    if value == nil then
        return
    end
    local dwidth = mp.get_property("dwidth")
    local dheight = mp.get_property("dheight")
    if dwidth ~= nil and dheight ~= nil and dwidth == last_dwidth and dheight == last_dheight then
        -- If video size stayed the same, then the scaling was probably done by the user to we save it
        local current_window_scale = mp.get_property("current-window-scale")
        prefered_win_width = dwidth * current_window_scale
    end
end

local function on_dwidth_change(_, value)
    if value == nil then
        return
    end
    local dwidth = mp.get_property("dwidth")
    local dheight = mp.get_property("dheight")
    if dwidth == nil or dheight == nil then
        return
    end

    -- Save new video size
    last_dwidth = dwidth
    last_dheight = dheight

    if prefered_win_width == nil then
        return
    end
    -- Scale window to prefered width
    local current_window_scale = mp.get_property("current-window-scale")
    local window_width = dwidth * current_window_scale
    local new_scale = current_window_scale
    if prefered_win_width ~= nil and math.abs(prefered_win_width - window_width) > 2 then
        new_scale = prefered_win_width / dwidth
    end

    if new_scale ~= current_window_scale then
        mp.set_property("window-scale", new_scale)
    end
end

local function menu_command(...)
    return {"script-message-to", script_name, ...}
end

local function open_uosc_menu()
    -- uosc menu

    local menu_data = {
        type = "yt_upnext_menu",
        title = "Youtube Recommendations",
        keep_open = true,
        items = {}
    }

    for i = 1, 16 do
        local icon = i % 2 == 0 and "movie" or "spinner"
        table.insert(
            menu_data["items"],
            {
                title = "",
                icon = icon,
                value = menu_command(),
                keep_open = true
            }
        )
    end

    local json = utils.format_json(menu_data)
    mp.commandv("script-message-to", "uosc", "open-menu", json)

    menu_data["items"] = {}

    local upnext, num_upnext = load_upnext()

    local url = mp.get_property("path")
    local not_youtube = url == nil or url:find("ytdl://") ~= 1 and url:find("https?://") ~= 1

    local play_action
    if opts.keep_playlist_on_select then
        play_action = "play"
    else
        play_action = "replace"
    end

    for i, v in ipairs(upnext) do
        if v ~= nil then
            local hint = tostring(i)
            if appended_to_playlist[v.file] == true then
                hint = '▷ ' .. hint
            end
            local video_item = {
                title = v.label,
                icon = "movie",
                hint = hint,
                keep_open = opts.uosc_keep_menu_open
            }
            if opts.uosc_entry_action == "submenu" then
                video_item["items"] = {
                    {
                        title = "Play",
                        value = menu_command(play_action, v.file, v.label),
                        keep_open = opts.uosc_keep_menu_open,
                        icon = 'play_circle',
                    },
                    {
                        title = "Up Next",
                        value = menu_command("insert", v.file, v.label),
                        keep_open = opts.uosc_keep_menu_open,
                        icon = 'queue',
                    },
                    {
                        title = "Add to playlist",
                        value = menu_command("append", v.file, v.label),
                        keep_open = opts.uosc_keep_menu_open,
                        icon = 'add_circle'
                    }
                }
            else
                video_item["value"] = menu_command(opts.uosc_entry_action, v.file, v.label)
            end
            table.insert(menu_data["items"], video_item)
        end
    end

    if not_youtube and num_upnext == 0 then
        table.insert(
            menu_data["items"],
            1,
            {
                title = "Current file is not a youtube video",
                icon = "warning",
                value = menu_command(),
                bold = true,
                active = 1,
                keep_open = false
            }
        )
    elseif num_upnext == 0 then
        table.insert(
            menu_data["items"],
            1,
            {
                title = "No results",
                icon = "warning",
                value = menu_command(),
                bold = true,
                active = 1,
                keep_open = false
            }
        )
    end

    json = utils.format_json(menu_data)
    mp.commandv("script-message-to", "uosc", "update-menu", json)
end

-- register script message to show menu
mp.register_script_message(
    "toggle-upnext-menu",
    function()
        if destroyer ~= nil then
            destroyer()
        else
            show_menu()
        end
    end
)

-- keybind to launch menu
mp.add_key_binding(opts.toggle_menu_binding, "upnext-menu", show_menu)

if opts.auto_add then
    mp.register_event("start-file", on_file_start)
elseif opts.fetch_on_start then
    mp.register_event("start-file", load_upnext)
end

if opts.restore_window_width then
    mp.observe_property("current-window-scale", "number", on_window_scale_changed)
    mp.observe_property("dwidth", "number", on_dwidth_change)
end

-- Open the uosc menu:

mp.register_script_message(
    "menu",
    function()
        open_uosc_menu()
    end
)

-- Handle the menu commands from usoc:

mp.register_script_message(
    "play",
    function(url, label)
        add_to_playlist(url, label, "append-play")
        local playlist_index_current = tonumber(mp.get_property("playlist-current-pos", "1"))
        local playlist_index_newfile = tonumber(mp.get_property("playlist-count", "1")) - 1
        mp.commandv("playlist-move", playlist_index_newfile, playlist_index_current + 1)
        mp.commandv("playlist-play-index", playlist_index_current + 1)
        appended_to_playlist[url] = true
    end
)

mp.register_script_message(
    "replace",
    function(url, label)
        add_to_playlist(url, label, "replace")
    end
)

mp.register_script_message(
    "insert",
    function(url, label)
        add_to_playlist(url, label, "append")
        local playlist_index_current = tonumber(mp.get_property("playlist-current-pos", "1"))
        local playlist_index_newfile = tonumber(mp.get_property("playlist-count", "1")) - 1
        mp.commandv("playlist-move", playlist_index_newfile, playlist_index_current + 1)
        appended_to_playlist[url] = true
    end
)

mp.register_script_message(
    "append",
    function(url, label)
        add_to_playlist(url, label, "append")
        appended_to_playlist[url] = true
    end
)
