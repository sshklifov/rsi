" if exists('')
"   finish
" endif

func s:DefineOption(name, def)
  if !exists(a:name)
    if type(a:def) == v:t_number
      exe printf("let %s = %d", a:name, a:def)
    else
      exe printf("let %s = %s", a:name, string(a:def))
    endif
  endif
endfunc

call s:DefineOption('g:rsi_file', "rsi.txt")
call s:DefineOption('g:rsi_work_secs', 60)
call s:DefineOption('g:rsi_rest_secs' 10)

let s:is_working = 1
" TODO not right
let s:last_time = localtime()
let s:period = g:rsi_work_secs

function RsiStatusline()
  let now = localtime()
  let elapsed = now - s:last_time
  let percentage = elapsed * 100 / s:period
  if percentage < 100
    return printf("%s %s%%", s:is_working ? "Working" : Resting, percentage)
  endif
  if s:is_working
    return printf("Take a rest (%d%%)!", percentage)
  else
    let s:last_time = localtime()
    let s:period = g:rsi_work_secs
    let s:is_working = 1
    return "0%"
  endif
endfunction

function RsiRest()
  let s:last_time = localtime()
  let s:period = g:rsi_rest_secs
  let s:is_working = 0
endfunction
