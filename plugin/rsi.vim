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
  let s:rest_point = 0
  let s:start_point = localtime()
  call RsiEnterWork()
endfunction

function! RsiEnterWork()
  let now = localtime()
  if s:rest_point > 0
    call s:RegisterRestPeriod(s:rest_point, now)
  endif
  let s:rest_point = 0

  let s:last_time = now
  let s:period = g:rsi_work_secs
  let s:working = 1
  let s:expired = 0
  call s:UpdateStatus()
endfunction

function! RsiEnterRest()
  let now = localtime()
  let s:rest_point = now
  let s:last_time = now
  let s:period = g:rsi_rest_secs
  let s:working = 0
  let s:expired = 0
  call s:UpdateStatus()
endfunction

function! s:RegisterRestPeriod(from, to)
  if !exists('s:rests_made')
    let s:rests_made = []
  endif
  call add(s:rests_made, [a:from, a:to])
endfunction

function! RsiPrintStats()
  if get(s:, 'rests_made', []) == []
    echo "No stats"
    return
  endif
  echo "RSI stats..."

  let total_rest = 0
  let total_work = 0
  let work_point = s:start_point
  for [rest_begin, rest_end] in s:rests_made
    let rest_secs = rest_end - rest_begin
    let total_rest += rest_secs
    if work_point > rest_begin
      throw "Invalid state, check " .. s:rsi_file
    endif
    let work_secs = rest_begin - work_point
    let total_work += work_secs
    echo "Worked from " .. strftime("%H:%M", work_point) .. " to " .. strftime("%H:%M", rest_begin) .. "."
    if work_secs > g:rsi_work_secs
      echo "Overworked " .. s:Format(work_secs - g:rsi_work_secs) .. "!"
    endif
    let work_point = rest_end
    echo "Rested " .. s:Format(rest_secs) .. "."
  endfor
  echo "Total working time: " .. s:Format(total_work)
  echo "Total resting time: " .. s:Format(total_rest)
  echo "Total: " .. s:Format(total_work + total_rest)
endfunction

function! s:OnFocusGained()
  let then = getftime(s:rsi_file)
  let now = localtime()
  let elapsed = now - then
  call s:RestoreState()

  if !s:prompt
    let expected_date = strftime("%F", now)
    if strftime("%F", s:start_point) != expected_date
      call RsiReset()
    elseif elapsed > g:rsi_reset_secs
      let msg = s:Format(elapsed) .. " passed with no activity (and counting). Mark as rest? "
      let opts = #{prompt: msg, text: "y", cancelreturn: "n"}
      " Show to other instances there is an open prompt
      let s:prompt = 1
      call s:FlushState()
      let user_response = input(opts)[0]
      let s:prompt = 0
      " Cher user input
      if user_response !=? 'n'
        " Recalculate current time
        let now = localtime()
        call s:RegisterRestPeriod(then, now)
        call RsiEnterWork()
      endif
      call s:FlushState()
    endif
  endif

  call s:UpdateStatus()
  call jobstart("touch " .. s:rsi_file)
endfunction

function! s:OnFocusLost()
  call s:FlushState()
  call jobstart("touch " .. s:rsi_file)
endfunction

function! s:FlushState()
  " Write out all script local variables
  call writefile([string(s:)], s:rsi_file)
endfunction

function! s:RestoreState()
  let cache = readfile(s:rsi_file)
  if len(cache) > 0
    let dict = eval(cache[0])
    for varname in keys(dict)
      let s:[varname] = dict[varname]
    endfor
  endif
endfunction

function RsiPeriod()
  let secs = localtime() - s:last_time
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
  if s:prompt
    let status = 'Prompt'
  else
    let now = localtime()
    let elapsed = now - s:last_time
    let percentage = elapsed * 10 / s:period
    if percentage < 10 && !s:expired
      let state = s:working ? "Working " : "Resting "
      let status = state .. percentage .. '/10'
    else
      let s:expired = 1
      if s:working
        let status = 'Stop'
      else
        let status = 'Transition'
        augroup Rsi
          autocmd! CursorMoved,CursorMovedI,InsertEnter,InsertLeave * ++once call RsiEnterWork()
        augroup END
      endif
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

function s:OnVimEnter()
  call s:OnFocusGained()
  call timer_start(s:TickRate(), 's:UpdateStatus', #{repeat: -1})

  augroup Rsi
    autocmd! FocusLost * call s:OnFocusLost()
    autocmd! FocusGained * call s:OnFocusGained()
    autocmd! VimLeavePre * ++once call s:OnFocusLost()
  augroup END
endfunction

augroup Rsi
  autocmd! VimEnter * ++once call s:OnVimEnter()
augroup END
