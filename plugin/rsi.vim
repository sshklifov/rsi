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

call s:DefineOption('g:rsi_file', 'rsi.txt')
call s:DefineOption('g:rsi_work_secs', 60 * 28)
call s:DefineOption('g:rsi_rest_secs', 45)
call s:DefineOption('g:rsi_reset_secs', 120)

let s:rsi_file = stdpath("state") .. "/rsi.txt"

function! RsiDebug()
  return copy(s:)
endfunction

function! RsiReset()
  let s:rests_made = []
  let s:stats_start = localtime()
  if exists('s:period_start')
    unlet s:period_start
  endif
  call RsiEnterWork()
  call s:FlushState()
endfunction

function! RsiEnterWork()
  let now = localtime()
  if exists('s:period_start')
    call s:RegisterRestPeriod(s:period_start, now)
  endif
  let s:last_activity = now
  let s:period_start = now
  let s:working = 1
  call s:UpdateStatus()
endfunction

function! RsiEnterRest()
  let now = localtime()
  let s:last_activity = now
  let s:period_start = now
  let s:working = 0
  call s:UpdateStatus()
endfunction

function! s:RegisterRestPeriod(from, to)
  if !exists('s:rests_made')
    let s:rests_made = []
  endif
  if a:from < a:to
    call add(s:rests_made, [a:from, a:to])
  else
    call init#Warn('RSI: Dropping invalid rest period!')
  endif
endfunction

function! RsiPrintStats()
  if get(s:, 'rests_made', []) == []
    echo "No stats"
    return
  endif
  echo "RSI stats..."

  let total_rest = 0
  let total_work = 0
  let work_point = s:stats_start
  for [rest_begin, rest_end] in s:rests_made
    let rest_secs = rest_end - rest_begin
    let total_rest += rest_secs
    let work_secs = rest_begin - work_point
    let total_work += work_secs
    echo "Worked from " .. strftime("%H:%M", work_point) .. " to " .. strftime("%H:%M", rest_begin) .. "."
    if work_secs > g:rsi_work_secs
      let msg = "Overworked " .. s:Format(work_secs - g:rsi_work_secs) .. "!"
      call init#Warn(msg)
    endif
    let work_point = rest_end
    echo "Rested " .. s:Format(rest_secs) .. "."
  endfor
  echo "Total working time: " .. s:Format(total_work)
  echo "Total resting time: " .. s:Format(total_rest)
  echo "Total: " .. s:Format(total_work + total_rest)
endfunction

function! s:OnVimLeave()
  if exists('s:status_timer')
    call timer_stop(s:status_timer)
  endif
  if exists('s:monitor_timer')
    call timer_stop(s:monitor_timer)
  endif
  if exists('s:monitor_job')
    call jobstop(s:monitor_job)
  endif
  call s:FlushState()
endfunction

function! s:FlushState()
  " Write out all script local variables
  let dict = filter(copy(s:), 'index(s:SavedVars(), v:key) >= 0')
  call writefile([string(dict)], s:rsi_file)
endfunction

function! s:SavedVars()
  return ['rests_made', 'stats_start', 'period_start', 'working', 'last_activity']
endfunction

function! s:RestoreState()
  if !filereadable(s:rsi_file)
    return
  endif
  let cache = readfile(s:rsi_file)
  if len(cache) > 0
    let dict = eval(cache[0])
    for varname in keys(dict)
      let s:[varname] = dict[varname]
    endfor
  endif
endfunction

function! RsiPeriod()
  if !exists('s:period_start')
    return '???'
  endif
  let secs = localtime() - s:period_start
  return s:Format(secs)
endfunction

function s:Format(x)
  let secs = a:x % 60
  let mins = (a:x / 60) % 60
  let hrs = (a:x / 60 / 60)
  if hrs > 0
    return printf("%dh %dm %ds", hrs, mins, secs)
  elseif mins > 0
    return printf("%dm %ds", mins, secs)
  else
    return printf("%ds", secs)
  endif
endfunction

function s:UpdateStatus(...)
  let now = localtime()
  let elapsed = now - s:period_start
  let period = s:working ? g:rsi_work_secs : g:rsi_rest_secs
  let percentage = elapsed * 10 / period
  let expired = elapsed >= period
  if !expired
    let state = s:working ? "Working " : "Resting "
    let status = state .. percentage .. '/10'
  else
    if s:working
      let status = 'Stop'
    else
      let status = 'Transition'
      augroup Rsi
        autocmd! CursorMoved,CursorMovedI,InsertEnter,InsertLeave * ++once call RsiEnterWork()
      augroup END
    endif
  endif

  if !has_key(g:statusline_dict, 'rsi') || g:statusline_dict['rsi'] != status
    let g:statusline_dict['rsi'] = status
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

function! s:MonitorKdeActivity()
  if !empty($SSH_CONNECTION)
    return v:false
  endif
  let cmd = ["dbus-monitor", "interface=org.kde.KWin.VirtualDesktopManager,member=currentChanged"]
  let opts = #{on_stdout: 's:OnActivity'}
  let id = jobstart(cmd, opts)
  if id <= 0
    return v:false
  endif
  let s:monitor_job = id
  return v:true
endfunction

function! s:MonitorVimActivity(...)
  augroup Rsi
    autocmd! CursorMoved,CursorMovedI,InsertEnter,InsertLeave * ++once call s:OnActivity()
  augroup END
endfunction

function s:OnActivity(...)
  let now = localtime()
  if !exists('s:last_activity')
    let s:last_activity = now
    return
  endif

  let elapsed = now - s:last_activity
  let s:last_activity = now
  if elapsed <= g:rsi_reset_secs || !s:working
    return
  endif

  let msg = s:Format(elapsed) .. " passed with no activity (and counting). Mark as rest? "
  let user_response = input(#{prompt: msg, text: "y", cancelreturn: "n"})[0]
  if user_response !=? 'n'
    " Recalculate current time
    call s:RegisterRestPeriod(s:last_activity, localtime())
    call RsiEnterWork()
  endif
endfunction

function! s:OnVimEnter()
  call s:RestoreState()
  let expected_date = strftime("%F")
  if !exists('s:stats_start') || strftime("%F", s:stats_start) != expected_date
    call RsiReset()
  endif

  call s:UpdateStatus()
  let s:status_timer = timer_start(s:TickRate(), 's:UpdateStatus', #{repeat: -1})

  const monitor = s:MonitorKdeActivity()
  if monitor
    let s:monitor_timer = timer_start(1000, 's:MonitorVimActivity', #{repeat: -1})
  else
    call init#Warn('RSI: Not monitoring for activity')
  endif

  augroup Rsi
    autocmd! VimLeavePre * ++once call s:OnVimLeave()
  augroup END
endfunction

function! RsiEnable()
  if v:vim_did_enter
    call s:OnVimEnter()
  else
    augroup Rsi
      autocmd! VimEnter * ++once call s:OnVimEnter()
    augroup END
  endif
endfunction

function! RsiDisable()
  augroup Rsi
    autocmd! VimLeavePre
    autocmd! CursorMoved,CursorMovedI,InsertEnter,InsertLeave
  augroup END
  call s:OnVimLeave()
  let g:statusline_dict['rsi'] = ''
endfunction
