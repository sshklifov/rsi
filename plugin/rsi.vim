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

function! rsi#Work()
  let now = localtime()
  if s:state_machine == 'resting'
    call add(s:history, [s:state_machine, s:period_begin, now])
  endif
  call s:WorkSilent(now)
  call s:FlushState()
endfunction

function! s:WorkSilent(...)
  augroup RsiTransition
    autocmd!
  augroup END

  let now = get(a:000, 0, localtime())
  let s:last_activity = now
  let s:period_begin = now
  let s:state_machine = 'working'
  call s:UpdateStatusline()
endfunction

function! rsi#Rest()
  let now = localtime()
  if s:state_machine == 'working'
    call add(s:history, [s:state_machine, s:period_begin, now])
  endif

  let s:last_activity = now
  let s:period_begin = now
  let s:state_machine = 'resting'
  call s:FlushState()
endfunction

function! rsi#Print()
  if empty(s:history)
    echo "No history"
    return
  endif
  echo "RSI history..."

  let total_rest = 0
  let total_work = 0
  for [type, begin, end] in s:history
    let secs = end - begin
    if type == 'resting'
      let total_rest += secs
      echo printf("Rested %s.", init#PrettyTime(secs))
    else
      let total_work += secs
      echo printf("Worked from %s to %s.", strftime("%H:%M", begin), strftime("%H:%M", end))
      if secs > g:rsi_work_secs
        let msg = printf("Overworked %s!", init#PrettyTime(secs - g:rsi_work_secs))
        call init#Warn(msg)
      endif
    endif
  endfor
  echo "Total working time: " .. init#PrettyTime(total_work)
  echo "Total resting time: " .. init#PrettyTime(total_rest)
  echo "Total: " .. init#PrettyTime(total_work + total_rest)
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
  endif
endfunction

function s:UpdateStatusline(...)
  let now = localtime()
  let elapsed = now - s:period_begin
  let working = s:state_machine == 'working'
  let max_secs = working ? g:rsi_work_secs : g:rsi_rest_secs
  let percentage = elapsed * 10 / max_secs
  let expired = elapsed >= max_secs
  if !expired
    let description = working ? "Working " : "Resting "
    let statusline = description .. percentage .. '/10'
  else
    if working
      let overworked = (elapsed - max_secs) / 60
      if overworked < 10
        let statusline = printf('Stop %dm', overworked)
      else
        let statusline = printf("Stop %dm. Rest. Go water a plant or something.", overworked)
      endif
    else
      let statusline = 'Transition'
      augroup RsiTransition
        autocmd! CursorMoved,CursorMovedI,InsertEnter,InsertLeave * call rsi#Work()
      augroup END
    endif
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

function! s:MonitorX11()
  augroup Rsi
    autocmd! CursorMoved,CursorMovedI,CmdlineChanged,InsertEnter,InsertLeave * call s:OnActivity()
  augroup END

  let cmd = ["xprop", "-root", "-spy", "_NET_CURRENT_DESKTOP"]
  let opts = #{on_stdout: expand("<SID>") .. 'OnActivity'}
  let s:monitor_job = init#Jobstart(cmd, opts)
  if s:monitor_job <= 0
    call init#Warn('RSI: Not monitoring for workspace activity')
  endif
  call s:OnActivity()
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

function s:OnActivity(...)
  let now = localtime()
  let prev_activity = s:last_activity
  let s:last_activity = now

  let idle_time = now - prev_activity
  if idle_time >= g:rsi_reset_threshold
    return rsi#Reset()
  endif

  let in_transition = get(g:statusline_dict, 'rsi', '') == 'Transition'
  if in_transition
    return rsi#Work()
  endif

  if s:state_machine == 'working' && idle_time > g:rsi_rest_threshold
    call add(s:history, ['working', s:period_begin, prev_activity])
    call add(s:history, ['resting', prev_activity, now])
    call s:WorkSilent(now)
    call s:FlushState()
  endif
endfunction

function! s:OnVimEnter()
  if empty(s:StateFiles())
    " First run: seed from the bootstrap shipped next to this script. Its stale
    " timestamps make the OnActivity() in MonitorX11 reset it to fresh state at
    " once, so it's just a placeholder that gets replaced immediately.
    call writefile(readfile(s:bootstrap), s:rsi_dir .. "/bootstrap.txt")
  endif

  call s:RestoreState()
  if !exists('s:rsi_file')
    call init#Warn('RSI: unlikely bug observed - restart Vim.')
    return
  endif

  let s:status_timer = timer_start(s:TickRate(), 's:UpdateStatusline', #{repeat: -1})
  call s:MonitorX11()
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
