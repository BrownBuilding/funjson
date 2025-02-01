package main

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import "core:os"

// TODO: Do allocators

Null :: struct {}

Value :: union #no_nil {
    Null,
    bool,
    f64,
    string, // i wish there was a way to express that this is an owned string like rust's std::String or C++'s std::string
    [dynamic]Value,
    map[string]Value,
}

main :: proc() {
    buffer := make([dynamic]u8)
    resize(&buffer, 1_048_576)
    // cannot use os.read_entire_file because it checks the size of the file which i guess is not possible with stdin
    read_bytes, ok0 := os.read(os.stdin, buffer[:])
    read_bytes -= 1 // i'm not a posix expert i don't know why it counts one extra
    read_content := string(buffer[:read_bytes])

    object, ok := pop_object(&read_content)
    if ok {
        if len(read_content) != 0 {
            fmt.println("the beginning of the file is valid json but there some non json at the end")
            os.exit(2)
        } else {
            fmt.println("this looks like json to me")
        }
        os.exit(0)
    } else {
        fmt.println("i don't think that this is valid json sorry")
        os.exit(1)
    }
}

/*
Create an object value from string literals and values. Take ownership over `value`.
`value` gets deallocated when `value_delete` is called on the returned object.
*/
make_value_object :: proc(key_value_pairs: ..struct {key: string, value: Value}) -> Value {
    object := make(map[string]Value)
    for kvp in key_value_pairs {
        str := strings.clone_from(kvp.key)
        object[str] = kvp.value
    }
    return object
}

/*
Creat an object value from string literals and values. Take ownership over `value`.
value gets deallocated when `value_delete` is called on the returned object.
*/
make_value_array :: proc(values: ..Value) -> Value {
    array := make([dynamic]Value)
    for v in values {
        append(&array, v)
    }
    return array
}

pop_object :: proc(text: ^string) -> (object: map[string]Value, ok: bool) {
    og_text := text^
    object = make(map[string]Value)
    defer if !ok {
        text^ = og_text
        delete(object)
    }

    pop_empty_object :: proc(text: ^string) -> (ok: bool) {
        og_text := text^
        defer if !ok do text^ = og_text
        if !pop_rune_if_equal(text, '{') do return
        pop_whitespace(text)
        if !pop_rune_if_equal(text, '}') do return
        return true
    }

    if pop_empty_object(text) {
        return object, true
    }

    if !pop_rune_if_equal(text, '{') do return

    pop_string_value_pair :: proc(text: ^string) -> (str: string, value: Value, ok: bool) {
        og_text := text^
        defer if !ok {
            text^ = og_text
            delete(str)
            value_delete(value)
        }
        pop_whitespace(text)
        str = pop_string(text) or_return
        pop_whitespace(text)
        if !pop_rune_if_equal(text, ':') do return
        value = pop_value(text) or_return
        ok = true
        return
    }

    str, v := pop_string_value_pair(text) or_return
    map_insert(&object, str, v)
    for {
        if !pop_rune_if_equal(text, ',') do break
        str, v := pop_string_value_pair(text) or_return
        map_insert(&object, str, v)
    }

    if !pop_rune_if_equal(text, '}') do return

    return object, true
}

value_equal :: proc(a: Value, b: Value) -> bool {
    switch av in a {
    case Null:
        bv, ok := b.(Null)
        return ok && bv == av
    case bool:
        bv, ok := b.(bool)
        return ok && bv == av
    case f64:
        bv, ok := b.(f64)
        return ok && bv == av
    case string:
        bv, ok := b.(string)
        return ok && bv == av
    case [dynamic]Value:
        bv, ok := b.([dynamic]Value)
        if len(av) != len(bv) do return false
        for i in 0 ..< len(av) {
            if !value_equal(av[i], bv[i]) do return false
        }
        return true
    case map[string]Value:
        bv, ok := b.(map[string]Value)
        if !ok do return false
        if len(bv) != len(av) do return false
        for bk, be in bv {
            ae, ok := av[bk]
            if !ok do return false
            if !value_equal(ae, be) do return false
        }
        return true
    }
    return false
}

@(test)
test_value_equal :: proc(t: ^testing.T) {
    object_a := make_value_object(
        {"wow", 543},
        {"ok", make_value_array(string_clone("hello"), 4, make_value_object({"hi", 53}))},
    )
    defer value_delete(object_a)
    object_b := make_value_object(
        {"wow", 543},
        {"ok", make_value_array(string_clone("hello"), 4, make_value_object({"hi", 53}))},
    )
    defer value_delete(object_b)
    object_c := make_value_object(
        {"wow", 543},
        {"ok", make_value_array(string_clone("helli"), 4, make_value_object({"hi", 53}))},
    )
    defer value_delete(object_c)
    testing.expect(t, value_equal(object_a, object_b))
    testing.expect(t, !value_equal(object_a, object_c))
}

value_delete :: proc(value: Value) {
    switch v in value {
    case Null:
    case bool:
    case f64:
    case string:
        delete(v)
    case [dynamic]Value:
        for e in v {
            value_delete(e)
        }
        delete(v)
    case map[string]Value:
        for k, e in v {
            value_delete(e)
            delete(k)
        }
        delete(v)
    }
}

pop_array :: proc(text: ^string) -> (array: [dynamic]Value, ok: bool) {
    og_text := text^
    return_value := make([dynamic]Value)
    defer if !ok {
        delete(return_value)
        text^ = og_text
    }

    // handle " '[' <whitespace> ']' "
    pop_empty_array :: proc(text: ^string) -> (ok: bool) {
        og_text := text^
        defer if !ok {
            text^ = og_text
        }
        if !pop_rune_if_equal(text, '[') do return
        pop_whitespace(text)
        if !pop_rune_if_equal(text, ']') do return
        ok = true
        return
    }
    if pop_empty_array(text) do return return_value, true

    // handle array filled with values
    if !pop_rune_if_equal(text, '[') do return
    if value, ok := pop_value(text); ok {
        append(&return_value, value)
    } else {
        return
    }
    for {
        if !pop_rune_if_equal(text, ',') do break
        if value, ok := pop_value(text); ok {
            append(&return_value, value)
        } else {
            return
        }
    }
    if !pop_rune_if_equal(text, ']') do return

    return return_value, true
}

@(test)
test_pop_array :: proc(t: ^testing.T) {
    things := [?]struct{text: string, expected_value: Value, expected_remaining_text: string, should_succed: bool } {
        {"[   \r ]thisis it luigi", make_value_array(), "thisis it luigi", true},
        {"[\"hello\",1]", make_value_array(string_clone("hello"), 1), "", true},
        {"[5,   [3,2,4,1]]what", make_value_array(5, make_value_array(3, 2, 4, 1)), "what", true},
        {"[[3, 2, 4, 1]]", make_value_array(make_value_array(3, 2, 4, 1)), "", true},
        {"[[],[], []]", make_value_array(make_value_array(), make_value_array(), make_value_array()), "", true},
        {"[[],[], []", Null{}, "[[],[], []", false},
        {"[1, 2, 3, 4, 5, 6,]", Null{}, "[1, 2, 3, 4, 5, 6,]", false}, // trailing comma is not permitted
    }
    defer for e in things do value_delete(e.expected_value)
    for e in things {
        text := e.text
        arr, ok := pop_array(&text)
        defer if ok do value_delete(arr)

        if e.should_succed {
            testing.expect_value(t, ok, true)
            testing.expect(t, value_equal(arr, e.expected_value))
            testing.expect_value(t, text, e.expected_remaining_text)
        } else {
            testing.expect_value(t, ok, false)
            testing.expect_value(t, text, e.expected_remaining_text)
        }
    }
}

pop_value :: proc(text: ^string) -> (value: Value, ok: bool) {
    og_text := text^
    defer {
        if !ok {
            text^ = og_text
        } else {
            pop_whitespace(text)
        }
    }
    pop_whitespace(text)
    if pop_prefix(text, "null") do return Null{}, true
    if pop_prefix(text, "false") do return false, true
    if pop_prefix(text, "true") do return true, true
    if array, ok := pop_array(text); ok do return array, true
    if object, ok := pop_object(text); ok do return object, true
    if str, ok := pop_string(text); ok do return str, true
    if number, ok := pop_number(text); ok do return number, true
    ok = false
    return
}

@(test)
test_pop_value :: proc(t: ^testing.T) {
    do_expect :: proc(
        t: ^testing.T,
        str: string,
        value: Value,
        should_fail: bool = false,
        remaining: string = "",
    ) {
        str := str
        result, ok := pop_value(&str)
        defer if ok do value_delete(result)
        defer value_delete(value)
        if should_fail {
            if ok do testing.fail(t)
        } else {
            if !ok do testing.fail(t)
            if !value_equal(result, value) {
                fmt.panicf("error while parsing %s\n", str)
            }
            // testing.expect_value(t, result, value)
        }
        testing.expect_value(t, str, remaining)
    }
    do_expect(t, "falsedi", false, false, "di")
    do_expect(t, "true,", true, false, ",")
    do_expect(t, "-549032.02,", -549032.02, false, ",")
    do_expect(t, "\"hi.\"", string_clone("hi."), false, "")
    do_expect(t, "hihihi", Null{}, true, "hihihi")
    do_expect(t, "nullfjdsakofpdasjfidokspaa", Null{}, false, "fjdsakofpdasjfidokspaa")
    do_expect(t, "nullfjdsakofpdasjfidokspaa", Null{}, false, "fjdsakofpdasjfidokspaa")
    do_expect(t, "{ }fdsjfkds", make_value_object(), false, "fdsjfkds")
    do_expect(t, "{ \"hi\": 43 }fdsjfkds", make_value_object({"hi", 43}), false, "fdsjfkds")
    do_expect(t, "{ \"hi\": { \"what\": [ 3, 4, 5, 6 ]} }fdsjfkds", make_value_object({"hi", make_value_object({"what", make_value_array(3, 4, 5, 6 )})}), false, "fdsjfkds")
}

pop_prefix :: proc(text: ^string, prefix: string) -> (ok: bool) {
    if prefix == "" do return true
    trimed := strings.trim_prefix(text^, prefix)
    ok = len(trimed) != len(text)
    text^ = trimed
    return
}

pop_string :: proc(text: ^string) -> (str: string, ok: bool) {
    // TODO: Implement 'u 4 hex digit'
    old_text := text^
    defer if !ok do text^ = old_text

    if !pop_rune_if_equal(text, '"') do return

    non_control_nor_qoute_nor_backslash :: proc(r: rune) -> bool {
        if r == '\\' || r == '"' do return false
        if utf8.is_control(r) do return false
        return true
    }

    str_buffer := make([dynamic]u8)
    defer if !ok {
        delete(str_buffer)
        str_buffer = nil
    }

    for {
        if popped_rune, ok := pop_rune_if(text, non_control_nor_qoute_nor_backslash); ok {
            encoded_rune, rune_length := utf8.encode_rune(popped_rune)
            for i in 0 ..< rune_length do append(&str_buffer, encoded_rune[i])
        } else if pop_rune_if_equal(text, '\\') {
            rune_after_backslash := pop_rune_if(text, may_follow_backslash) or_return
            meant_char := escape_char_to_char(rune_after_backslash) or_return
            append(&str_buffer, u8(meant_char))
        } else if pop_rune_if_equal(text, '"') {
            break
        } else {
            return
        }
    }

    str = string(str_buffer[:])
    assert(utf8.valid_string(str))
    ok = true
    return

    may_follow_backslash :: proc(r: rune) -> bool {
        switch r {
        case '"':
            fallthrough
        case '\\':
            fallthrough
        case '/':
            fallthrough
        case 'b':
            fallthrough
        case 'f':
            fallthrough
        case 'n':
            fallthrough
        case 'r':
            fallthrough
        case 't':
            return true
        // case 'u': fallthrough
        }
        return false
    }

    escape_char_to_char :: proc(r: rune) -> (rr: rune, ok: bool) {
        switch r {
        case '"':
            return '"', true
        case '\\':
            return '\\', true
        case '/':
            return '/', true
        case 'b':
            return '\b', true
        case 'f':
            return '\f', true
        case 'n':
            return '\n', true
        case 'r':
            return '\r', true
        case 't':
            return '\t', true
        }
        ok = false
        return
    }
}

@(test)
test_pop_string :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 1 * time.Second)
    {
        some_text := "\"This is it \"Luigi"
        str, ok := pop_string(&some_text)
        defer if ok do delete(str)
        if !ok do testing.fail(t)
        testing.expect_value(t, str, "This is it ")
        testing.expect_value(t, some_text, "Luigi")
    }
    {
        some_text := "\"This \\n is \\tit \\\" \"Luigi"
        str, ok := pop_string(&some_text)
        defer if ok do delete(str)
        if !ok do testing.fail(t)
        testing.expect_value(t, str, "This \n is \tit \" ")
        testing.expect_value(t, some_text, "Luigi")
    }
    {
        some_text := "\"-549032.02,\" "
        str, ok := pop_string(&some_text)
        defer if ok do delete(str)
        if !ok do testing.fail(t)
        testing.expect_value(t, str, "-549032.02,")
        testing.expect_value(t, some_text, " ")
    }
    {     // test preserving of original string in case of error
        some_text := "\"This \\n is \\a \\tit \\\" \"Luigi"
        //                            ^ invalid escape
        str, ok := pop_string(&some_text)
        testing.expect_value(t, ok, false)
        defer if ok do delete(str)
        testing.expect_value(t, some_text, "\"This \\n is \\a \\tit \\\" \"Luigi")
    }
    {
        some_text := "\"I am not closed"
        str, ok := pop_string(&some_text)
        testing.expect_value(t, ok, false)
        defer if ok do delete(str)
        testing.expect_value(t, some_text, "\"I am not closed")
    }
}

pop_number :: proc(
    text: ^ /*mut*/string,
) -> (
    number: f64,
    ok: bool,
) {
    // TODO: do exponents
    // TODO: emit error for nubmers larger than 64 characters
    og_text := text^

    defer if !ok {
        text^ = og_text
    }

    is_negative := pop_rune_if_equal(text, '-')
    if pop_rune_if_equal(text, '0') do return 0, true

    if is_negative do assert(len(og_text) == len(text^) + 1)

    digit_buffer := [64]u8{} // maybe use Small_Array
    digit_buffer_cursor := 0

    check_non_zero_digit :: proc(r: rune) -> bool {return '0' < r && r <= '9'}
    if popped_rune, ok := pop_rune_if(text, check_non_zero_digit); ok {
        digit_buffer[digit_buffer_cursor] = u8(popped_rune)
        digit_buffer_cursor += 1
    } else {
        return
    }

    check_digit :: proc(r: rune) -> bool {return '0' <= r && r <= '9'}
    for digit_rune in pop_rune_if(text, check_digit) {
        digit_buffer[digit_buffer_cursor] = u8(digit_rune)
        digit_buffer_cursor += 1
        at_least_one_digit := true
    }

    // parse fraction
    if pop_rune_if_equal(text, '.') {
        digit_buffer[digit_buffer_cursor] = u8('.')
        digit_buffer_cursor += 1
        at_least_one_digit_after_decimal_point := false
        for digit_rune in pop_rune_if(text, check_digit) {
            digit_buffer[digit_buffer_cursor] = u8(digit_rune)
            digit_buffer_cursor += 1
            at_least_one_digit_after_decimal_point = true
        }
        if !at_least_one_digit_after_decimal_point {
            return
        }
    }

    number = strconv.atof(string(digit_buffer[:digit_buffer_cursor]))
    if is_negative do number = -number

    ok = true
    return
}

@(test)
test_pop_number :: proc(t: ^testing.T) {
    {     // check parsing
        some_text := "-42,59803,-0,0,3.14,-549032.02,"
        expected := [?]f64{-42, 59803, -0, 0, 3.14, -549032.02}
        for i in 0 ..< len(expected) {
            result, ok := pop_number(&some_text)
            if !ok do fmt.panicf("could not parse %d", expected[i])
            testing.expect_value(t, result, expected[i])
            if !pop_rune_if_equal(&some_text, ',') {
                fmt.panicf("could not pop ',' after parsing %f", expected[i])
            }
        }
        testing.expect_value(t, some_text, "")
    }
    {     // test checking for missing diget after '.'
        some_text := "4832.fsadfs"
        result, ok := pop_number(&some_text)
        testing.expect_value(t, ok, false)
        testing.expect_value(t, result, 0)
        testing.expect_value(t, some_text, "4832.fsadfs")
    }
    // the following test is invalid:
    // { // check restoring to original text
    //     some_text := "03fsadfs"
    //     result, ok := pop_number(&some_text)
    //     testing.expect_value(t, ok, false)
    //     testing.expect_value(t, result, 0)
    //     testing.expect_value(t, some_text, "03fsadfs")
    // }
}

/*
this is basically just `peek`
*/
pop_rune_if_equal :: proc(text: ^string, r: rune) -> bool {
    zero_text := text^
    if popped_rune, ok := pop_rune(&zero_text); ok && popped_rune == r {
        text^ = zero_text
        return true
    }
    return false
    // I really wish i could just write this instead:
    // `return pop_rune_if(text, proc(nested_r: rune) -> bool { return nested_r == r })`
    // but capturing is just to complex for odin i guess
    // TODO: Maybe generics? wait no i don't think you can overload the call-operator in odin
}

pop_rune_if :: proc(text: ^string, f: proc(_: rune) -> bool) -> (rune, bool) {
    zero_text := text^
    if popped_rune, ok := pop_rune(&zero_text); ok && f(popped_rune) {
        text^ = zero_text
        return popped_rune, true
    }
    return 0, false
}

pop_rune :: proc(text: ^string) -> (rune, bool) {
    if text == nil do return 0, false
    if text^ == "" do return 0, false
    character, rune_size := utf8.decode_rune(text^)
    text^ = text[rune_size:]
    return character, true
}

@(test)
test_pop_rune :: proc(t: ^testing.T) {
    some_text := "hel😭lo ﷽"
    fmt.printfln("This is itl uigi, %x", uint('😭'))
    runes := [?]rune {
        pop_rune(&some_text) or_else testing.fail_now(t),
        pop_rune(&some_text) or_else testing.fail_now(t),
        pop_rune(&some_text) or_else testing.fail_now(t),
        pop_rune(&some_text) or_else testing.fail_now(t),
        pop_rune(&some_text) or_else testing.fail_now(t),
        pop_rune(&some_text) or_else testing.fail_now(t),
        pop_rune(&some_text) or_else testing.fail_now(t),
        pop_rune(&some_text) or_else testing.fail_now(t),
    }
    testing.expect_value(t, runes, [?]rune{'h', 'e', 'l', '😭', 'l', 'o', ' ', '﷽'})
}

pop_whitespace :: proc(text: ^string) {
    offset := 0
    for ch in text^ {
        switch ch {
        case ' ':
            fallthrough
        case '\n':
            fallthrough
        case '\r':
            fallthrough
        case '\t':
            offset += 1
            continue
        }
        break
    }
    text^ = text[offset:]
}

@(test)
test_pop_whitespace :: proc(t: ^testing.T) {
    some_text := "  \r  \n   \t \n  hi  "
    pop_whitespace(&some_text)
    testing.expect_value(t, some_text, "hi  ")
}

string_clone :: proc(str: string) -> string {
    return strings.clone(str) or_else panic("could not clone string")
}
