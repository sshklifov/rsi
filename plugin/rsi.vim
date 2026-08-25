" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

if exists('*RsiStatusline')
  finish
endif

function! s:DefineOption(name, def)
  if !exists(a:name)
    if type(a:def) == v:t_number
      exe printf("let %s = %d", a:name, a:def)
    else
      exe printf("let %s = %s", a:name, string(a:def))
    endif
  endif
endfunction

call s:DefineOption('g:rsi_work_secs', 1680)
call s:DefineOption('g:rsi_rest_secs', 60)
call s:DefineOption('g:rsi_rest_threshold', 900)
call s:DefineOption('g:rsi_reset_threshold', 14400)

let s:rsi_dir = stdpath("state") .. "/rsi"
let s:bootstrap = expand('<sfile>:p:h') .. "/bootstrap.txt"
let s:idle = expand('<sfile>:p:h') .. "/idle.py"

call mkdir(s:rsi_dir, "p")

function! s:StateFiles()
  return glob(s:rsi_dir .. "/*.txt", 0, 1)
endfunction

function! rsi#Debug()
  return deepcopy(s:)
endfunction

function! rsi#OpenStateFile()
  let files = s:StateFiles()
  call qutil#DropInQuickfix(files, 'State files')
endfunction

function! rsi#Reset()
  let s:history = []
  call s:WorkSilent()
  call s:FlushState()
endfunction

" The periods tile the time from the first one we saw up to period_begin: no
" holes, no overlaps. Only a real change of state ends a period, so being told
" what we are already doing leaves the open period alone -- restarting it would
" drop everything since period_begin on the floor.
function! rsi#Work()
  if s:state_machine == 'working'
    " Nothing happened, but the trigger that called us has fired for good.
    call s:ClearTransition()
    return
  endif

  let now = localtime()
  " A period that began this very second is no period at all.
  if now > s:period_begin
    call add(s:history, [s:state_machine, s:period_begin, now])
  endif
  call s:WorkSilent(now)
  call s:FlushState()
endfunction

function! s:ClearTransition()
  augroup RsiTransition
    autocmd!
  augroup END
endfunction

function! s:WorkSilent(...)
  let now = get(a:000, 0, localtime())
  let s:last_activity = now
  let s:period_begin = now
  let s:state_machine = 'working'
  call s:UpdateStatusline()
endfunction

function! rsi#Rest()
  if s:state_machine == 'resting'
    return
  endif

  let now = localtime()
  " A period that began this very second is no period at all.
  if now > s:period_begin
    call add(s:history, [s:state_machine, s:period_begin, now])
  endif

  let s:last_activity = now
  let s:period_begin = now
  let s:state_machine = 'resting'
  call s:FlushState()
endfunction

" Glyph and highlight for each kind of time. Outside is the hour we had not
" started in yet and the rest of the one we are living through; away is a hole
" in the middle of the day. Neither is time we can account for, so both wear
" the dot, but only away is ours to answer for and counts in the totals.
let s:glyphs = #{
      \ working: ['█', 'MoreMsg'],
      \ overworked: ['▓', 'WarningMsg'],
      \ resting: ['░', 'Comment'],
      \ away: ['·', 'NonText'],
      \ outside: ['·', 'NonText'],
      \ }
let s:kinds = ['working', 'overworked', 'resting', 'away']
let s:bar_width = 24

" Durations read as a column of numbers here, so no seconds unless that is all
" there is -- an hour boundary can cut a rest into two slivers.
function! s:Duration(secs)
  if a:secs < 60
    return printf("%ds", a:secs)
  endif
  let mins = (a:secs + 30) / 60
  if mins >= 60
    return printf("%dh %02dm", mins / 60, mins % 60)
  endif
  return printf("%dm", mins)
endfunction

" One hour as it happened: [kind, seconds] runs in clock order. A period is cut
" at the hour on both ends, so one spanning the boundary lands in both hours,
" and a work period is cut once more where it turns into overwork.
function! s:HourSegments(periods, hour, first, last)
  let stop = a:hour + 3600
  let segments = []
  let cursor = a:hour
  for [type, begin, end] in a:periods
    let from = max([begin, a:hour])
    let to = min([end, stop])
    if to <= from
      continue
    endif
    if from > cursor
      call add(segments, [cursor < a:first ? 'outside' : 'away', from - cursor])
    endif
    let split = type == 'working' ? min([max([begin + g:rsi_work_secs, from]), to]) : to
    call add(segments, [type, split - from])
    call add(segments, ['overworked', to - split])
    let cursor = to
  endfor
  if cursor < stop
    call add(segments, [cursor >= a:last ? 'outside' : 'away', stop - cursor])
  endif
  return filter(segments, 'v:val[1] > 0')
endfunction

function! s:CountKinds(segments)
  let counts = #{working: 0, overworked: 0, resting: 0, away: 0, outside: 0}
  for [kind, secs] in a:segments
    let counts[kind] += secs
  endfor
  return counts
endfunction

" A bar as echo chunks: every segment gets cells in proportion, cut from the
" running total so rounding cannot leave a gap in a full hour, and never fewer
" than one cell once it is worth a minute. The rest of the width stays blank.
function! s:BarChunks(segments, total)
  let chunks = []
  let filled = 0
  let elapsed = 0
  for [kind, secs] in a:segments
    let elapsed += secs
    let cells = min([max([elapsed * s:bar_width / a:total - filled, secs >= 30]), s:bar_width - filled])
    if cells <= 0
      continue
    endif
    let [glyph, hl] = s:glyphs[kind]
    if !empty(chunks) && chunks[-1][1] == hl
      let chunks[-1][0] ..= repeat(glyph, cells)
    else
      call add(chunks, [repeat(glyph, cells), hl])
    endif
    let filled += cells
  endfor
  call add(chunks, [repeat(' ', s:bar_width - filled), 'Normal'])
  return chunks
endfunction

" The minute columns trailing an hour row, in fixed slots so they line up.
" Overwork is work, so it counts towards both the work and the over column.
function! s:HourColumns(counts)
  let columns = []
  for [secs, label] in [[a:counts.working + a:counts.overworked, 'work'], [a:counts.resting, 'rest'], [a:counts.overworked, 'over']]
    call add(columns, secs > 0 ? printf("%6s %-4s", s:Duration(secs), label) : repeat(' ', 11))
  endfor
  let text = substitute(join(columns, ' '), '\s\+$', '', '')
  return empty(text) ? "   away" : "   " .. text
endfunction

function! rsi#Print()
  let now = localtime()
  let periods = filter(copy(s:history) + [[s:state_machine, s:period_begin, now]], 'v:val[1] < v:val[2]')
  if empty(periods)
    echo "No history"
    return
  endif

  let first = periods[0][1]
  let last = periods[-1][2]
  " Whole local hours, so a row is exactly one hour on the clock.
  let from = strptime("%Y-%m-%d %H", strftime("%Y-%m-%d %H", first))
  let to = from + ((last - from) / 3600 + 1) * 3600
  let attendance = last - first

  let hours = range(from, to - 1, 3600)
  let segments = map(copy(hours), 's:HourSegments(periods, v:val, first, last)')
  let buckets = map(copy(segments), 's:CountKinds(v:val)')
  let labels = map(copy(hours), 'strftime("%H", v:val) .. "  "')

  let header = printf("%s → %s   %s\n", init#PrettyDate(first), strftime("%H:%M", last), s:Duration(attendance))
  let chunks = [[header, 'Title']]

  call add(chunks, ["\n"])
  for i in range(len(hours))
    call add(chunks, [labels[i], 'LineNr'])
    call extend(chunks, s:BarChunks(segments[i], 3600))
    call add(chunks, [s:HourColumns(buckets[i]) .. "\n"])
  endfor

  let totals = #{working: 0, overworked: 0, resting: 0, away: 0}
  for counts in buckets
    for kind in s:kinds
      let totals[kind] += counts[kind]
    endfor
  endfor

  call add(chunks, ["\n"])
  let rows = [
        \ ['Worked', [['working', totals.working], ['overworked', totals.overworked]]],
        \ ['Rested', [['resting', totals.resting]]],
        \ ['Away', [['away', totals.away]]],
        \ ['Overworked', [['overworked', totals.overworked]]],
        \ ]
  for [label, row] in rows
    let secs = 0
    for [kind, kind_secs] in row
      let secs += kind_secs
    endfor
    if secs <= 0
      continue
    endif
    call add(chunks, [printf("%-10s %8s  ", label, s:Duration(secs))])
    call extend(chunks, s:BarChunks(row, attendance))
    call add(chunks, [printf("  %3d%%\n", secs * 100 / attendance)])
  endfor

  " No trailing blank line, it only costs another hit-enter.
  let chunks[-1][0] = substitute(chunks[-1][0], "\n$", '', '')
  call nvim_echo(chunks, v:true, #{})
endfunction

function! s:OnVimLeave()
  let g:statusline_dict['rsi'] = ''

  if exists('s:status_timer')
    call timer_stop(s:status_timer)
  endif
  if exists('s:monitor_timer')
    call timer_stop(s:monitor_timer)
  endif
  if exists('s:monitor_job')
    call jobstop(s:monitor_job)
  endif
  if exists('s:watch_job')
    call jobstop(s:watch_job)
  endif
  call s:FlushState()
endfunction

function! s:FlushState()
  call s:UpdateStatusline()

  const vars = ['history', 'period_begin', 'state_machine', 'last_activity']
  let dict = filter(copy(s:), 'index(vars, v:key) >= 0')
  " Sort the items for a stable representation.
  let content = string(sort(items(dict)))
  let new_file = printf("%s/%s.txt", s:rsi_dir, sha256(content))

  " State unchanged (same hash): nothing to do, only spurious triggers land here.
  if filereadable(new_file)
    return
  endif

  " Atomic swap: publish the new state, then claim it by deleting the previous
  " file. delete() succeeds for exactly one racer, so if it fails someone else
  " already swapped -- adopt their state and drop our own.
  call writefile([content], new_file)

  let old_file = s:rsi_file
  let s:rsi_file = new_file
  if delete(old_file) != 0
    call delete(new_file)
    call s:RestoreState()
  endif
endfunction

function! s:RestoreState()
  let files = s:StateFiles()
  if len(files) != 1
    " Wait for the directory to settle back to a single file.
    return
  endif
  if exists('s:rsi_file') && filereadable(s:rsi_file)
    " Already loaded
    return
  endif

  let s:rsi_file = files[0]
  let cache = readfile(s:rsi_file)
  if len(cache) > 0
    for [varname, value] in eval(cache[0])
      let s:[varname] = value
    endfor

    " The file's last_activity is only as fresh as whoever wrote it last, so it
    " says when this state was last true -- not when anybody last touched a key.
    " Staleness is exactly the question the day boundary asks, and exactly the
    " wrong one to ask about a rest: measuring the next keystroke against it is
    " how a second instance used to invent an afternoon off.
    let stale = localtime() - s:last_activity
    let s:last_activity = localtime()
    if stale >= g:rsi_reset_threshold
      call rsi#Reset()
    endif
  endif
endfunction

function s:UpdateStatusline(...)
  let now = localtime()
  let elapsed = now - s:period_begin
  let working = s:state_machine == 'working'
  let max_secs = working ? g:rsi_work_secs : g:rsi_rest_secs
  let percentage = elapsed * 10 / max_secs
  let expired = elapsed >= max_secs
  let in_transition = expired && !working
  if !expired
    let description = working ? "Working " : "Resting "
    let statusline = description .. percentage .. '/10'
  elseif working
    let overworked = (elapsed - max_secs) / 60
    if overworked < 10
      let statusline = printf('Stop %dm', overworked)
    else
      let statusline = printf("Stop %dm. Rest. Go water a plant or something.", overworked)
    endif
  else
    let statusline = 'Transition'
  endif

  " Armed only while we are waiting out a finished rest. Disarming everywhere
  " else matters because the state can arrive from another instance, and a
  " trigger left over from what we used to be would fire on the next keystroke.
  if in_transition
    augroup RsiTransition
      autocmd! CursorMoved,CursorMovedI,InsertEnter,InsertLeave * call rsi#Work()
    augroup END
  else
    call s:ClearTransition()
  endif

  if !has_key(g:statusline_dict, 'rsi') || g:statusline_dict['rsi'] != statusline
    let g:statusline_dict['rsi'] = statusline
  endif
endfunction

function s:CommonDivisor(x, y)
  if a:y == 0
    return a:x
  endif
  return s:CommonDivisor(a:y, a:x % a:y)
endfunction

function! s:TickRate()
  let tick_sec = s:CommonDivisor(g:rsi_rest_secs, g:rsi_work_secs) / 10.0
  let tick_msec = float2nr(tick_sec * 1000)
  return tick_msec
endfunction

function! s:MonitorActivity()
  augroup Rsi
    autocmd! CursorMoved,CursorMovedI,CmdlineChanged,InsertEnter,InsertLeave * call s:OnActivity()
  augroup END

  " A workspace switch is not the only thing that happens outside this window:
  " an hour of reading in a browser is work too, and nothing in here can hear
  " it. The helper reports what the X server saw, on the tick we already keep.
  let cmd = ["python3", s:idle, printf("%.3f", s:TickRate() / 1000.0)]
  let opts = #{on_stdout: expand("<SID>") .. 'OnIdleReport'}
  let s:monitor_job = init#Jobstart(cmd, opts)
  if s:monitor_job <= 0
    call init#Warn('RSI: Not monitoring for input outside Vim')
  endif
  call s:OnActivity()
endfunction

" Idle milliseconds, so the last input is that far back. Only a moment we have
" not counted yet is news; while nobody touches anything it stays put, which is
" exactly how being away is supposed to look.
" A line that is not a number is a poll that found the screen locked, and input
" the lock screen swallowed is not ours to count.
function s:OnIdleReport(id, data, event)
  for line in a:data
    if line !~ '^\d\+$'
      continue
    endif
    let input = localtime() - str2nr(line) / 1000
    if input > s:last_activity
      call s:Activity(input)
    endif
  endfor
endfunction

function! s:WatchStateFile()
  let cmd = ["inotifywait", "--monitor", "--event", "delete", s:rsi_dir]
  let opts = #{on_stdout: expand("<SID>") .. 'OnFileChanged'}
  let s:watch_job = init#Jobstart(cmd, opts)
  if s:watch_job <= 0
    call init#Warn('RSI: Not watching state file')
  endif
endfunction

function s:OnFileChanged(...)
  call s:RestoreState()
  call s:UpdateStatusline()
endfunction

" Vim's own events are a lower bound on activity: they say when something
" happened in here, never when nothing happened anywhere.
function s:OnActivity(...)
  call s:Activity(localtime())
endfunction

function s:Activity(now)
  let prev_activity = s:last_activity
  let s:last_activity = a:now

  let idle_time = a:now - prev_activity
  if idle_time >= g:rsi_reset_threshold
    return rsi#Reset()
  endif

  " Away long enough to count as rest: the work ended with the last thing we
  " saw. State adopted from another instance can carry a last_activity older
  " than our period_begin, and a period may not end before it began.
  if s:state_machine == 'working' && idle_time > g:rsi_rest_threshold
    let split = max([prev_activity, s:period_begin])
    if split > s:period_begin
      call add(s:history, ['working', s:period_begin, split])
    endif
    call add(s:history, ['resting', split, a:now])
    call s:WorkSilent(a:now)
    call s:FlushState()
    return
  endif

  if get(g:statusline_dict, 'rsi', '') == 'Transition'
    call rsi#Work()
  endif
endfunction

function! s:OnVimEnter()
  if empty(s:StateFiles())
    " First run: seed from the bootstrap shipped next to this script. Its stale
    " timestamps make the OnActivity() in MonitorActivity reset it to fresh
    " state at once, so it's just a placeholder that gets replaced immediately.
    call writefile(readfile(s:bootstrap), s:rsi_dir .. "/bootstrap.txt")
  endif

  call s:RestoreState()
  if !exists('s:rsi_file')
    call init#Warn('RSI: unlikely bug observed - restart Vim.')
    return
  endif

  let s:status_timer = timer_start(s:TickRate(), 's:UpdateStatusline', #{repeat: -1})
  call s:MonitorActivity()
  call s:WatchStateFile()
  call s:UpdateStatusline()

  augroup Rsi
    autocmd! VimLeavePre * ++once call s:OnVimLeave()
  augroup END
endfunction

function! rsi#Disable()
  augroup Rsi
    autocmd!
  augroup END
  augroup RsiTransition
    autocmd!
  augroup END
  call s:OnVimLeave()
endfunction

augroup Rsi
  autocmd! VimEnter * ++once call s:OnVimEnter()
augroup END
