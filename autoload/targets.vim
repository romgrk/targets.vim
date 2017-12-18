" targets.vim Provides additional text objects
" Author:  Christian Wellenbrock <christian.wellenbrock@gmail.com>
" License: MIT license

" save cpoptions
let s:save_cpoptions = &cpoptions
set cpo&vim

" called once when loaded
function! s:setup()
    " maps kind to factory constructor
    let s:registry = {
                \ 'pairs':      function('targets#sources#pairs#new'),
                \ 'tags':       function('targets#sources#tags#new'),
                \ 'quotes':     function('targets#sources#quotes#new'),
                \ 'separators': function('targets#sources#separators#new'),
                \ 'arguments':  function('targets#sources#arguments#new'),
                \ }

    let g:targets_argOpening   = get(g:, 'targets_argOpening', '[([]')
    let g:targets_argClosing   = get(g:, 'targets_argClosing', '[])]')
    let g:targets_argSeparator = get(g:, 'targets_argSeparator', ',')

    let s:rangeScores = {}
    let ranges = split(get(g:, 'targets_seekRanges',
                \ 'cr cb cB lc ac Ac lr rr ll lb ar ab lB Ar aB Ab AB rb al rB Al bb aa bB Aa BB AA'))
    let rangesN = len(ranges)
    let i = 0
    while i < rangesN
        let s:rangeScores[ranges[i]] = rangesN - i
        let i = i + 1
    endwhile

    let s:rangeJumps = {}
    let ranges = split(get(g:, 'targets_jumpRanges', 'bb bB BB aa Aa AA'))
    let rangesN = len(ranges)
    let i = 0
    while i < rangesN
        let s:rangeJumps[ranges[i]] = 1
        let i = i + 1
    endwhile

    " currently undocumented, currently not supposed to be user defined
    " but could be used to disable 'smart' quote skipping
    " some technicalities: inverse mapping from quote reps to quote arg reps
    " quote rep '102' means:
    "   1: even number of quotation character left from cursor
    "   0: no quotation char under cursor
    "   2: even number (but nonzero) of quote chars right of cursor
    " arg rep 'r1l' means:
    "   r: select to right (l: to left; n: not at all)
    "   1: single speed (each quote char starts one text object)
    "      (2: double speed, skip pseudo quotes)
    "   l: skip first quote when going left ("last" quote objects)
    "      (r: skip once when going right ("next"); b: both; n: none)
    let g:targets_quoteDirs = get(g:, 'targets_quoteDirs', {
                \ 'r1n': ['001', '201', '100', '102'],
                \ 'r1l': ['010', '012', '111', '210', '212'],
                \ 'r2n': ['101'],
                \ 'r2l': ['011', '211'],
                \ 'r2b': ['000'],
                \ 'l2r': ['110', '112'],
                \ 'n2b': ['002', '200', '202'],
                \ })

    let g:targets_multis = get(g:, 'targets_multis', {
                \ 'b': { 'pairs':  [['(', ')'], ['[', ']'], ['{', '}']], },
                \ 'q': { 'quotes': [["'"], ['"'], ['`']], },
                \ })
endfunction

" a:count is unused here, but added for consistency with targets#x
function! targets#o(trigger, count)
    let context = s:init('o')

    " TODO: include kind in trigger so we don't have to guess as much?
    let [delimiter, which, modifier] = split(a:trigger, '\zs')
    let [target, rawTarget] = s:findTarget(context, delimiter, which, modifier, v:count1)
    if target.state().isInvalid()
        call s:abortMatch(context, '#o: ' . target.error)
        return s:cleanUp()
    endif
    call s:handleTarget(context, target, rawTarget)
    call s:clearCommandLine()
    call s:prepareRepeat(delimiter, which, modifier)
    call s:cleanUp()
endfunction

" 'e' is for expression; return expression to execute, used for visual
" mappings to not break non-targets visual mappings
" and for operator pending mode as well if possible to speed up plugin loading
" time
function! targets#e(modifier)
    let mode = mode(1)
    if mode ==? 'v' " visual mode, from xnoremap
        let prefix = "\<Esc>:\<C-U>call targets#x('"
    elseif mode ==# 'no' " operator pending, from onoremap
        let prefix = ":call targets#o('"
    else
        return a:modifier
    endif

    let char1 = nr2char(getchar())
    let [delimiter, which, chars] = [char1, 'c', char1]
    let i = 0
    while i < 2
        if g:targets_nl[i] ==# delimiter
            " delimiter was which, get another char for delimiter
            let char2 = nr2char(getchar())
            let [delimiter, which, chars] = [char2, 'nl'[i], chars . char2]
            break
        endif
        let i = i + 1
    endwhile

    if empty(s:getFactories(delimiter))
        return a:modifier . chars
    endif

    if delimiter ==# "'"
        let delimiter = "''"
    endif

    return prefix . delimiter . which . a:modifier . "', " . v:count1 . ")\<CR>"
endfunction

" 'x' is for visual (as in :xnoremap, not in select mode)
function! targets#x(trigger, count)
    let context = s:initX()

    let [delimiter, which, modifier] = split(a:trigger, '\zs')
    let [target, rawTarget] = s:findTarget(context, delimiter, which, modifier, a:count)
    if target.state().isInvalid()
        call s:abortMatch(context, '#x: ' . target.error)
        return s:cleanUp()
    endif
    if s:handleTarget(context, target, rawTarget) == 0
        let s:lastTarget = target
        let s:lastRawTarget = rawTarget
    endif
    call s:cleanUp()
endfunction

" initialize script local variables for the current matching
function! s:init(mapmode)
    let s:newSelection = 1

    let s:selection = &selection  " remember 'selection' setting
    let &selection  = 'inclusive' " and set it to inclusive

    let s:virtualedit = &virtualedit " remember 'virtualedit' setting
    let &virtualedit  = ''           " and set it to default

    let s:whichwrap = &whichwrap " remember 'whichwrap' setting
    let &whichwrap  = 'b,s'      " and set it to default

    return {
                \ 'mapmode': a:mapmode,
                \ 'oldpos':  getpos('.'),
                \ 'minline': line('w0'),
                \ 'maxline': line('w$'),
                \ 'withOldpos': function('s:contextWithOldpos'),
                \ }
endfunction

" save old visual selection to detect new selections and reselect on fail
function! s:initX()
    let context = s:init('x')

    let s:visualTarget = targets#target#fromVisualSelection(s:selection)

    " reselect, save mode and go back to normal mode
    normal! gv
    if mode() ==# 'V'
        let s:visualTarget.linewise = 1
        normal! V
    else
        normal! v
    endif

    let s:newSelection = s:isNewSelection()
    return context
endfunction

" clean up script variables after match
function! s:cleanUp()
    " reset remembered settings
    let &selection   = s:selection
    let &virtualedit = s:virtualedit
    let &whichwrap   = s:whichwrap
endfunction

function! s:findTarget(context, delimiter, which, modifier, count)
    let factories = s:getFactories(a:delimiter)
    if empty(factories)
        let errorTarget = targets#target#withError("failed to find delimiter")
        return [errorTarget, errorTarget]
    endif

    let view = winsaveview()
    let rawTarget = s:findRawTarget(a:context, factories, a:which, a:count)
    let target = s:modifyTarget(rawTarget, a:modifier)
    call winrestview(view)
    return [target, rawTarget]
endfunction

function! s:findRawTarget(context, factories, which, count)
    let context = a:context

    if a:which ==# 'c'
        if a:count == 1 && s:newSelection " seek
            let gen = s:newMultiGen(context)
            call gen.add(a:factories, 'C', 'N', 'L')

        else " don't seek
            if !s:newSelection " start from last raw end
                let context = context.withOldpos(s:lastRawTarget.getposE())
            endif
            let gen = s:newMultiGen(context)
            call gen.add(a:factories, 'C')
        endif

    elseif a:which ==# 'n'
        if !s:newSelection " start from last raw start
            let context = context.withOldpos(s:lastRawTarget.getposS())
        endif
        let gen = s:newMultiGen(context)
        call gen.add(a:factories, 'N')

    elseif a:which ==# 'l'
        if !s:newSelection " start from last raw end
            let context = context.withOldpos(s:lastRawTarget.getposE())
        endif
        let gen = s:newMultiGen(context)
        call gen.add(a:factories, 'L')

    else
        return targets#target#withError('findRawTarget which')
    endif

    return gen.nextN(a:count)
endfunction

function! s:modifyTarget(target, modifier)
    if a:target.state().isInvalid()
        return targets#target#withError('modifyTarget invalid: ' . a:target.error)
    endif

    let modFuncs = a:target.gen.modFuncs
    if !has_key(modFuncs, a:modifier)
        return targets#target#withError('modifyTarget')
    endif

    let Funcs = modFuncs[a:modifier]
    if type(Funcs) == type(function('tr')) " single function
        return Funcs(a:target.copy())
    endif

    let target = a:target.copy()
    for Func in Funcs " list of functions
        let target = Func(target)
    endfor
    return target
endfunction

" returns list of [kind, argsForKind], potentially empty
function! s:getFactories(trigger)
    " create cache
    if !exists('s:factoriesCache')
        let s:factoriesCache = {}
    endif

    " check cache
    if has_key(s:factoriesCache, a:trigger)
        let factories = s:factoriesCache[a:trigger]
        return factories
    endif

    let factories = s:getNewFactories(a:trigger)
    " write to cache (even if no factories were returned)
    let s:factoriesCache[a:trigger] = factories
    return factories
endfunction

" returns list of [kind, argsForKind], potentially empty
function! s:getNewFactories(trigger)
    let multi = get(g:targets_multis, a:trigger, 0)
    if type(multi) == type({})
        return s:getMultiFactories(multi)
    endif

    " check more specific ones first for #145
    if a:trigger ==# g:targets_tagTrigger " TODO: does this work with custom trigger?
        return [targets#sources#tags#new()]
    endif

    if a:trigger ==# g:targets_argTrigger " TODO: does this work with custom trigger?
        return [targets#sources#arguments#new(g:targets_argOpening, g:targets_argClosing, g:targets_argSeparator)]
    endif

    for pair in split(g:targets_pairs)
        for trigger in split(pair, '\zs')
            if trigger ==# a:trigger
                return [targets#sources#pairs#new(pair[0], pair[1])]
            endif
        endfor
    endfor

    for quote in split(g:targets_quotes)
        for trigger in split(quote, '\zs')
            if trigger ==# a:trigger
                return [targets#sources#quotes#new(quote[0])]
            endif
        endfor
    endfor

    for separator in split(g:targets_separators)
        for trigger in split(separator, '\zs')
            if trigger ==# a:trigger
                return [targets#sources#separators#new(separator[0])]
            endif
        endfor
    endfor

    return []
endfunction

function! s:getMultiFactories(multi)
    let factories = []
    for kind in keys(s:registry)
        for args in get(a:multi, kind, [])
            call add(factories, call(s:registry[kind], args))
        endfor
    endfor
    return factories
endfunction

" return 0 if the selection changed since the last invocation. used for
" growing
function! s:isNewSelection()
    " no previous invocation or target
    if !exists('s:lastTarget')
        return 1
    endif

    " selection changed
    if !s:lastTarget.equal(s:visualTarget)
        return 1
    endif

    return 0
endfunction

" clear the commandline to hide targets function calls
function! s:clearCommandLine()
    echo
endfunction

" handle the match by either selecting or aborting it
function! s:handleTarget(context, target, rawTarget)
    if a:target.state().isInvalid()
        return s:abortMatch(a:context, 'handleTarget')
    elseif a:target.state().isEmpty()
        return s:handleEmptyMatch(a:context, a:target)
    else
        return s:selectTarget(a:context, a:target, a:rawTarget)
    endif
endfunction

" select a proper match
function! s:selectTarget(context, target, rawTarget)
    " add old position to jump list
    if s:addToJumplist(a:context, a:rawTarget)
        call setpos('.', a:context.oldpos)
        normal! m'
    endif

    call s:selectRegion(a:target)
endfunction

function! s:addToJumplist(context, target)
    let range = a:target.range(a:context)[0]
    return get(s:rangeJumps, range)
endfunction

" visually select a given match. used for match or old selection
function! s:selectRegion(target)
    " visually select the target
    call a:target.select()

    " if selection should be exclusive, expand selection
    if s:selection ==# 'exclusive'
        normal! l
    endif
endfunction

" empty matches can't visually be selected
" most operators would like to move to the end delimiter
" for change or delete, insert temporary character that will be operated on
function! s:handleEmptyMatch(context, target)
    if a:context.mapmode !=# 'o' || v:operator !~# "^[cd]$"
        return s:abortMatch(a:context, 'handleEmptyMatch')
    endif

    " move cursor to delimiter after zero width match
    call a:target.cursorS()

    let eventignore = &eventignore " remember setting
    let &eventignore = 'all' " disable auto commands

    " insert single space and visually select it
    silent! execute "normal! i \<Esc>v"

    let &eventignore = eventignore " restore setting
endfunction

" abort when no match was found
function! s:abortMatch(context, message)
    " get into normal mode and beep
    if !exists("*getcmdwintype") || getcmdwintype() ==# ""
        call feedkeys("\<C-\>\<C-N>\<Esc>", 'n')
    endif

    call s:prepareReselect(a:context)
    call setpos('.', a:context.oldpos)

    " undo partial command
    call s:triggerUndo()
    " trigger reselect if called from xmap
    call s:triggerReselect(a:context)

    return targets#util#fail(a:message)
endfunction

" feed keys to call undo after aborted operation and clear the command line
function! s:triggerUndo()
    if exists("*undotree")
        let undoseq = undotree().seq_cur
        call feedkeys(":call targets#undo(" . undoseq . ")\<CR>:echo\<CR>", 'n')
    endif
endfunction

" temporarily select original selection to reselect later
function! s:prepareReselect(context)
    if a:context.mapmode ==# 'x'
        call s:selectRegion(s:visualTarget)
    endif
endfunction

" feed keys to reselect the last visual selection if called with mapmode x
function! s:triggerReselect(context)
    if a:context.mapmode ==# 'x'
        call feedkeys("gv", 'n')
    endif
endfunction

" set up repeat.vim for older Vim versions
function! s:prepareRepeat(delimiter, which, modifier)
    if v:version >= 704 " skip recent versions
        return
    endif

    if v:operator ==# 'y' && match(&cpoptions, 'y') ==# -1 " skip yank unless set up
        return
    endif

    " TODO: this wouldn't work with custom iaIAnl, right?
    " maybe the trigger args should just always include what's typed
    " and then we translate in here with the cache, potentially without splitting
    let cmd = v:operator . a:modifier
    if a:which !=# 'c'
        let cmd .= a:which
    endif
    let cmd .= a:delimiter
    if v:operator ==# 'c'
        let cmd .= "\<C-r>.\<ESC>"
    endif

    silent! call repeat#set(cmd, v:count)
endfunction

" undo last operation if it created a new undo position
function! targets#undo(lastseq)
    if undotree().seq_cur > a:lastseq
        silent! execute "normal! u"
    endif
endfunction

" select best of given targets according to s:rangeScores
" detects for each given target what range type it has, depending on the
" relative positions of the start and end of the target relative to the cursor
" position and the currently visible lines

" The possibly relative positions are:
"   c - on cursor position
"   l - left of cursor in current line
"   r - right of cursor in current line
"   a - above cursor on screen
"   b - below cursor on screen
"   A - above cursor off screen
"   B - below cursor off screen

" All possibly ranges are listed below, denoted by two characters: one for the
" relative start and for the relative end position each of the target. For
" example, `lr` means "from left of cursor to right of cursor in cursor line".

" Next to each range type is a pictogram of an example. They are made of these
" symbols:
"    .  - current cursor position
"   ( ) - start and end of target
"    /  - line break before and after cursor line
"    |  - screen edge between hidden and visible lines

" ranges on cursor:
"   cr   |  /  () /  |   starting on cursor, current line
"   cb   |  /  (  /) |   starting on cursor, multiline down, on screen
"   cB   |  /  (  /  |)  starting on cursor, multiline down, partially off screen
"   lc   |  / ()  /  |   ending on cursor, current line
"   ac   | (/  )  /  |   ending on cursor, multiline up, on screen
"   Ac  (|  /  )  /  |   ending on cursor, multiline up, partially off screen

" ranges around cursor:
"   lr   |  / (.) /  |   around cursor, current line
"   lb   |  / (.  /) |   around cursor, multiline down, on screen
"   ar   | (/  .) /  |   around cursor, multiline up, on screen
"   ab   | (/  .  /) |   around cursor, multiline both, on screen
"   lB   |  / (.  /  |)  around cursor, multiline down, partially off screen
"   Ar  (|  /  .) /  |   around cursor, multiline up, partially off screen
"   aB   | (/  .  /  |)  around cursor, multiline both, partially off screen bottom
"   Ab  (|  /  .  /) |   around cursor, multiline both, partially off screen top
"   AB  (|  /  .  /  |)  around cursor, multiline both, partially off screen both

" ranges after (right of/below) cursor
"   rr   |  /  .()/  |   after cursor, current line
"   rb   |  /  .( /) |   after cursor, multiline, on screen
"   rB   |  /  .( /  |)  after cursor, multiline, partially off screen
"   bb   |  /  .  /()|   after cursor below, on screen
"   bB   |  /  .  /( |)  after cursor below, partially off screen
"   BB   |  /  .  /  |() after cursor below, off screen

" ranges before (left of/above) cursor
"   ll   |  /().  /  |   before cursor, current line
"   al   | (/ ).  /  |   before cursor, multiline, on screen
"   Al  (|  / ).  /  |   before cursor, multiline, partially off screen
"   aa   |()/  .  /  |   before cursor above, on screen
"   Aa  (| )/  .  /  |   before cursor above, partially off screen
"   AA ()|  /  .  /  |   before cursor above, off screen

"     A  a  l r  b  B  relative positions
"      └───────────┘   visible screen
"         └─────┘      current line

" returns best target (and its index) according to range score and distance to cursor
function! s:bestTarget(targets, context, message)
    let [bestScore, minLines, minChars] = [0, 1/0, 1/0] " 1/0 = maxint

    let cnt = len(a:targets)
    for idx in range(cnt)
        let target = a:targets[idx]
        let [range, lines, chars] = target.range(a:context)
        let score = get(s:rangeScores, range)

        " if target.state().isValid()
        "     echom target.string()
        "     echom 'score ' . score . ' lines ' . lines . ' chars ' . chars
        " endif

        if (score > bestScore) ||
                    \ (score == bestScore && lines < minLines) ||
                    \ (score == bestScore && lines == minLines && chars < minChars)
            let [bestScore, minLines, minChars, best, bestIdx] = [score, lines, chars, target, idx]
        endif
    endfor

    if exists('best')
        " echom 'best ' . best.string()
        " echom 'score ' . bestScore . ' lines ' . minLines . ' chars ' . minChars
        return [best, bestIdx]
    endif

    return [targets#target#withError(a:message), -1]
endfunction

function! s:newMultiGen(context)
    return {
                \ 'gens':    [],
                \ 'context': a:context,
                \
                \ 'add':    function('s:multiGenAdd'),
                \ 'next':   function('s:multiGenNext'),
                \ 'nextN':  function('targets#generator#nextN'),
                \ 'target': function('targets#generator#target')
                \ }
endfunction

function! s:multiGenAdd(factories, ...) dict
    let whichs = a:000
    for factory in a:factories
        for which in whichs
            call add(self.gens, factory.new(self.context.oldpos, which))
        endfor
    endfor
endfunction

function! s:multiGenNext(first) dict
    if a:first
        for gen in self.gens
            let first = s:newSelection || s:lastRawTarget.gen.factory.trigger != gen.factory.trigger
            call gen.next(first)
        endfor
    else
        call self.currentTarget.gen.next(0) " fill up where we used the last target from
    endif

    let targets = []
    for gen in self.gens
        call add(targets, gen.target())
    endfor

    while 1
        let [target, idx] = s:bestTarget(targets, self.context, 'multigen')
        if target.state().isInvalid() " best is invalid -> done
            let self.currentTarget = target
            return self.currentTarget
        endif

        " TODO: can we merge current target and last raw target to avoid this
        " sort of duplication?
        if exists('self.currentTarget')
            if self.currentTarget.equal(target)
                " current target is the same as last one, skip it and try the next one
                let targets[idx] = target.gen.next(0)
                continue
            endif
        elseif !s:newSelection && s:lastRawTarget.equal(target)
            " current target is the same as continued one, skip it and try the next one
            " NOTE: this can happen if a multi contains two generators which
            " may create the same target. in that case growing might break
            " without this check
            let targets[idx] = target.gen.next(0)
            continue
        endif

        let self.currentTarget = target
        return self.currentTarget
    endwhile
endfunction

" TODO: move to separate file?
function s:contextWithOldpos(oldpos) dict
    let context = deepcopy(self)
    let context.oldpos = a:oldpos
    return context
endfunction

call s:setup()

" reset cpoptions
let &cpoptions = s:save_cpoptions
unlet s:save_cpoptions
