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
call s:DefineOption('g:rsi_work_secs', 1800)
call s:DefineOption('g:rsi_rest_secs', 40)
call s:DefineOption('g:rsi_reset_secs', 150)

let s:global_timestamp = stdpath("state") .. "/rsa.txt"

function RsiDebug()
  return s:
endfunction

function! RsiEnterWork()
  let s:last_time = localtime()
  let s:period = g:rsi_work_secs
  let s:working = 1
  let s:expired = 0
  call s:UpdateStatus()
endfunction

function! RsiEnterRest()
  let now = localtime()
  let overwork = now - s:last_time - s:period
  if s:working && s:expired
    echo "Overworked " .. overwork .. "s."
  endif
  let s:last_time = now
  let s:period = g:rsi_rest_secs
  let s:working = 0
  let s:expired = 0
  call s:UpdateStatus()
endfunction

function! s:OnCursorMoved()
  let now = localtime()
  let s:last_cursor_moved = now
  if !s:working && s:expired
    call RsiEnterWork()
  endif
  call jobstart("touch " .. s:global_timestamp)
endfunction

function! s:UpdateStatus()
  let now = localtime()
  let elapsed = now - s:last_time
  let percentage = elapsed * 10 / s:period
  if percentage < 10 && !s:expired
    let state = s:working ? "Working " : "Resting "
    let g:statusline_dict['rsi'] = state .. percentage .. '/10'
  else
    let s:expired = 1
    let g:statusline_dict['rsi'] = ''
  endif

  let elapsed = now - s:last_cursor_moved
  if elapsed > g:rsi_reset_secs
    let global_cursor_moved = getftime(s:global_timestamp)
    if global_cursor_moved > s:last_cursor_moved
      let s:last_cursor_moved = global_cursor_moved
    endif
    let elapsed = now - s:last_cursor_moved
    if s:working && elapsed > g:rsi_reset_secs
      let s:working = 0
      let s:expired = 1
    endif
  endif
endfunction

function! s:MainLoop(...)
  call s:UpdateStatus()
  " Reset activity detection. The '++once' is crucial here - this is in
  " the main loop so the callback is triggered at most once per tick.
  augroup Rsi
    autocmd! CursorMoved,CursorMovedI,InsertEnter,InsertLeave * ++once call s:OnCursorMoved()
  augroup END
endfunction

let s:last_cursor_moved = localtime()
call RsiEnterWork()
redrawstatus

call timer_start(1000, 's:MainLoop', #{repeat: -1})
