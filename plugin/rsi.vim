" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

" TODO bug: If i am in transition and a pop appears (for the same duration) that I have rested?

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
call s:DefineOption('g:rsi_work_secs', 1680)
call s:DefineOption('g:rsi_rest_secs', 60)
call s:DefineOption('g:prompt_threshold_secs', 900)
call s:DefineOption('g:reset_threshold_secs', 28800)

let s:rsi_file = stdpath("state") .. "/rsi.txt"

function! RsiDebug()
  return deepcopy(s:)
endfunction

function! s:Reset()
  let s:rests_made = []
  let s:stats_start = localtime()
  if exists('s:period_start')
    unlet s:period_start
  endif
  call s:EnterWork()
  call s:FlushState()
endfunction

function! s:EnterWork()
  augroup RsiTransition
    autocmd!
  augroup END

  let now = localtime()
  if exists('s:period_start')
    call s:RegisterRestPeriod(s:period_start, now)
  endif
  let s:last_activity = now
  let s:period_start = now
  let s:working = 1
  call s:UpdateStatus()
endfunction

function! s:EnterRest()
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
  if a:from >= a:to
    call init#Warn('RSI: Dropping invalid rest period (internal bug)!')
  elseif len(s:rests_made) > 0 && s:rests_made[-1][1] > a:from
    call init#Warn('RSI: Dropping invalid rest period (race condition)!')
  else
    call add(s:rests_made, [a:from, a:to])
  endif
endfunction

function! s:PrintStats()
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
      let overworked = (elapsed - period) / 60
      if overworked < 10
        let status = printf('Stop %dm', overworked)
      else
        let status = printf("Stop %dm. Rest. Go water a plant or something.", overworked)
      endif
    else
      let status = 'Transition'
      augroup RsiTransition
        autocmd! CursorMoved,CursorMovedI,InsertEnter,InsertLeave * call s:EnterWork()
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

function! s:MonitorActivity()
  augroup Rsi
    autocmd! CursorMoved,CursorMovedI,CmdlineChanged,InsertEnter,InsertLeave * call s:OnActivity()
  augroup END

  let cmd = ["dbus-monitor", "interface=org.kde.KWin.VirtualDesktopManager,member=currentChanged"]
  let opts = #{on_stdout: 's:OnActivity'}
  let s:monitor_job = jobstart(cmd, opts)
  if s:monitor_job <= 0
    call init#Warn('RSI: Not monitoring for KDE activity')
  endif
endfunction

function s:UpdateLastActivity()
  let s:last_activity = localtime()
endfunction

function s:CheckInactivity()
  if exists('s:last_activity')
    let now = localtime()
  endif
endfunction

function s:OnActivity(...)
  let now = localtime()
  if !exists('s:last_activity')
    let s:last_activity = now
    return
  endif

  let elapsed = now - s:last_activity
  let s:last_activity = now
  if elapsed >= g:reset_threshold_secs
    return s:Reset()
  endif
  if elapsed <= g:prompt_threshold_secs || !s:working
    return
  endif

  stopinsert
  let msg = s:Format(elapsed) .. " passed with no activity (and counting). Mark as rest?"
  let cmd = ["kdialog", "--yesno", msg]
  let id = jobstart(cmd)
  let ret = jobwait([id], 10000)[0]
  if ret == 0
    " Recalculate current time
    call s:RegisterRestPeriod(now - elapsed, localtime())
    if exists('s:period_start')
      unlet s:period_start
    endif
    call s:EnterWork()
  endif
endfunction

function! s:OnVimEnter()
  call s:RestoreState()
  let expected_date = strftime("%F")
  if !exists('s:stats_start') || strftime("%F", s:stats_start) != expected_date
    call s:Reset()
  endif

  call s:UpdateStatus()
  let s:status_timer = timer_start(s:TickRate(), 's:UpdateStatus', #{repeat: -1})
  call s:MonitorActivity()

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

function! RsiEnableOn(ws)
  " SSH connections will report the same workspace (how you last left your desktop).
  if !empty($SSH_CONNECTION)
    return
  endif

  let ws = systemlist("qdbus org.kde.KWin /KWin org.kde.KWin.currentDesktop")
  if v:shell_error
    call init#Warn("qdbus command failed!")
    return
  endif
  if ws[0] != a:ws
    return
  endif
  call RsiEnable()
endfunction

function! RsiDisable()
  augroup Rsi
    autocmd!
  augroup END
  augroup RsiTransition
    autocmd!
  augroup END
  call s:OnVimLeave()
  let g:statusline_dict['rsi'] = ''
endfunction

function! RsiCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let subc = ["Enable", "Disable", "Reset",
        \ "EnterWork", "EnterRest", "PrintStats"]
  return filter(subc, 'stridx(v:val, a:ArgLead) >= 0')
endfunction

function! s:RsiCommand(what)
  if a:what == "Enable"
    call RsiEnable()
  elseif exists('#Rsi#VimLeavePre')
    call eval("s:" .. a:what .. "()")
  else
    echo "Rsi plugin is not enabled."
  endif
endfunction

command! -nargs=1 -complete=customlist,RsiCompl Rsi call s:RsiCommand(<q-args>)
