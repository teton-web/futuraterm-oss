@testable import FuturaTerm
import Testing

struct NumberedChoiceParserTests {
    // MARK: - Required fixtures

    @Test
    func grok_two_options_parse_as_a_consecutive_run() {
        let text = """
        What would you like to do?

        1. Continue
        2. Always allow this command
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.index) == [1, 2])
        #expect(choices.map(\.label) == ["Continue", "Always allow this command"])
        #expect(choices.map(\.selected) == [false, false])
        #expect(choices.map(\.line) == [3, 4])
        #expect(choices.map(\.column) == [1, 1])
    }

    @Test
    func leading_pointer_marks_the_row_selected_and_shifts_the_digit_column() {
        let text = """
        ❯ 1. Continue
          2. Always allow this command
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.count == 2)
        #expect(choices[0].index == 1)
        #expect(choices[0].selected)
        #expect(choices[0].column == 3)
        #expect(choices[0].line == 1)
        #expect(choices[1].index == 2)
        #expect(!choices[1].selected)
        #expect(choices[1].column == 3)
        #expect(choices[1].line == 2)
    }

    @Test
    func closing_paren_form_is_accepted() {
        let text = """
        1) Continue
        2) Explain
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices == [
            NumberedChoice(index: 1, label: "Continue", line: 1, column: 1, selected: false),
            NumberedChoice(index: 2, label: "Explain", line: 2, column: 1, selected: false),
        ])
    }

    @Test
    func prose_containing_see_step_1_does_not_parse() {
        let text = """
        Please see step 1. before continuing.
        Then see step 2. if needed.
        """
        #expect(NumberedChoiceParser.parse(text).isEmpty)
    }

    @Test
    func a_single_numbered_line_is_not_a_menu() {
        #expect(NumberedChoiceParser.parse("1. foo").isEmpty)
    }

    @Test
    func one_then_three_without_two_drops_the_run() {
        let text = """
        1. foo
        3. bar
        """
        #expect(NumberedChoiceParser.parse(text).isEmpty)
    }

    // MARK: - Selection markers

    @Test
    func each_contract_marker_sets_selected() {
        let markers = [">", "❯", "*", "•", "o"]
        for marker in markers {
            let text = """
            \(marker) 1. First
              2. Second
            """
            let choices = NumberedChoiceParser.parse(text)
            #expect(choices.count == 2, "marker \(marker)")
            #expect(choices[0].selected, "marker \(marker)")
            #expect(!choices[1].selected, "marker \(marker)")
            #expect(choices[0].label == "First", "marker \(marker)")
        }
    }

    @Test
    func marker_may_sit_against_the_digits() {
        let choices = NumberedChoiceParser.parse(" >1. First\n  2. Second")
        #expect(choices.count == 2)
        #expect(choices[0].selected)
        #expect(choices[0].column == 3)
        #expect(choices[0].label == "First")
    }

    // MARK: - Run selection

    @Test
    func a_marked_menu_beats_a_longer_unmarked_plan() {
        let text = """
        1. Investigate
        2. Implement
        3. Verify

        ❯ 1. Continue
          2. Always allow this command
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.index) == [1, 2])
        #expect(choices.map(\.label) == ["Continue", "Always allow this command"])
        #expect(choices.map(\.selected) == [true, false])
        #expect(choices.map(\.line) == [5, 6])
    }

    @Test
    func among_marked_runs_start_at_one_beats_a_longer_selected_list() {
        let text = """
        > 2. Older
          3. Menu
          4. Items

        ❯ 1. Continue
          2. Stop
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.label) == ["Continue", "Stop"])
        #expect(choices[0].selected)
    }

    @Test
    func longest_run_wins_even_when_it_does_not_start_at_one() {
        let text = """
        1. short
        2. list

        10. alpha
        11. beta
        12. gamma
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.index) == [10, 11, 12])
        #expect(choices.map(\.label) == ["alpha", "beta", "gamma"])
        #expect(choices.map(\.line) == [4, 5, 6])
    }

    @Test
    func start_at_one_wins_a_length_tie() {
        let text = """
        1. keep
        2. this

        8. skip
        9. these
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.index) == [1, 2])
        #expect(choices.map(\.label) == ["keep", "this"])
    }

    @Test
    func earliest_start_at_one_run_wins_when_still_tied() {
        let text = """
        1. first
        2. menu

        1. second
        2. menu
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.label) == ["first", "menu"])
        #expect(choices.map(\.line) == [1, 2])
    }

    @Test
    func intervening_non_matching_lines_do_not_break_consecutive_indexes() {
        let text = """
        1. Continue

        (help text)

        2. Always allow
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.index) == [1, 2])
        #expect(choices.map(\.line) == [1, 5])
    }

    @Test
    func mixed_dot_and_paren_delimiters_still_form_a_run() {
        let text = """
        1. Continue
        2) Explain
        """
        #expect(NumberedChoiceParser.parse(text).map(\.index) == [1, 2])
    }

    @Test
    func run_may_start_after_one_when_that_is_the_only_viable_menu() {
        let text = """
        2. Next
        3. After
        """
        #expect(NumberedChoiceParser.parse(text).map(\.index) == [2, 3])
    }

    // MARK: - Non-matches / empty labels

    @Test
    func empty_input_and_blank_lines_yield_nothing() {
        #expect(NumberedChoiceParser.parse("").isEmpty)
        #expect(NumberedChoiceParser.parse("\n\n").isEmpty)
        #expect(NumberedChoiceParser.parse("   \t  ").isEmpty)
    }

    @Test
    func delimiter_without_a_following_label_is_dropped() {
        #expect(NumberedChoiceParser.parse("1.\n2. bar").isEmpty)
        #expect(NumberedChoiceParser.parse("1. foo\n2.").isEmpty)
        #expect(NumberedChoiceParser.parse("1.   \n2. bar").isEmpty)
    }

    @Test
    func no_space_after_the_delimiter_is_not_a_choice() {
        #expect(NumberedChoiceParser.parse("1.foo\n2.bar").isEmpty)
    }

    @Test
    func zero_and_leading_zeros_are_not_positive_indexes() {
        #expect(NumberedChoiceParser.parse("0. foo\n1. bar").isEmpty)
        #expect(NumberedChoiceParser.parse("01. foo\n02. bar").isEmpty)
    }

    @Test
    func oversized_digit_run_is_skipped_not_trapped() {
        let huge = String(repeating: "9", count: 40)
        let text = """
        \(huge). foo
        1. bar
        2. baz
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.index) == [1, 2])
        #expect(choices.map(\.label) == ["bar", "baz"])
    }

    @Test
    func int_max_index_does_not_overflow_when_checking_the_next_candidate() {
        let text = """
        \(Int.max). overflow
        1. bar
        2. baz
        """
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.index) == [1, 2])
        #expect(choices.map(\.label) == ["bar", "baz"])
    }

    @Test
    func labels_trim_trailing_spaces_and_keep_interior_text() {
        let text = "1.  Continue working  \n2. Always allow\t"
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.label) == ["Continue working", "Always allow"])
    }

    @Test
    func crlf_dump_still_numbers_lines_from_one() {
        let text = "1. Continue\r\n2. Explain\r\n"
        let choices = NumberedChoiceParser.parse(text)
        #expect(choices.map(\.index) == [1, 2])
        #expect(choices.map(\.line) == [1, 2])
        #expect(choices.map(\.label) == ["Continue", "Explain"])
    }

    @Test
    func same_text_is_deterministic() {
        let text = "❯ 1. A\n  2. B"
        let first = NumberedChoiceParser.parse(text)
        let second = NumberedChoiceParser.parse(text)
        #expect(first == second)
        #expect(first.map(\.index) == [1, 2])
    }
}
