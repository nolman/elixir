defmodule Code.Fragment do
  @moduledoc """
  This module provides conveniences for analyzing fragments of
  textual code and extract available information whenever possible.

  Most of the functions in this module provide a best-effort
  and may not be accurate under all circumstances. Read each
  documentation for more information.

  This module should be considered experimental.
  """

  @type position :: {line :: pos_integer(), column :: pos_integer()}

  @doc """
  Receives a string and returns the cursor context.

  This function receives a string with an Elixir code fragment,
  representing a cursor position, and based on the string, it
  provides contextual information about said position. The
  return of this function can then be used to provide tips,
  suggestions, and autocompletion functionality.

  This function provides a best-effort detection and may not be
  accurate under all circumstances. See the "Limitations"
  section below.

  Consider adding a catch-all clause when handling the return
  type of this function as new cursor information may be added
  in future releases.

  ## Examples

      iex> Code.Fragment.cursor_context("")
      :expr

      iex> Code.Fragment.cursor_context("hello_wor")
      {:local_or_var, 'hello_wor'}

  ## Return values

    * `{:alias, charlist}` - the context is an alias, potentially
      a nested one, such as `Hello.Wor` or `HelloWor`

    * `{:dot, inside_dot, charlist}` - the context is a dot
      where `inside_dot` is either a `{:var, charlist}`, `{:alias, charlist}`,
      `{:module_attribute, charlist}`, `{:unquoted_atom, charlist}` or a `dot`
      itself. If a var is given, this may either be a remote call or a map
      field access. Examples are `Hello.wor`, `:hello.wor`, `hello.wor`,
      `Hello.nested.wor`, `hello.nested.wor`, and `@hello.world`

    * `{:dot_arity, inside_dot, charlist}` - the context is a dot arity
      where `inside_dot` is either a `{:var, charlist}`, `{:alias, charlist}`,
      `{:module_attribute, charlist}`, `{:unquoted_atom, charlist}` or a `dot`
      itself. If a var is given, it must be a remote arity. Examples are
      `Hello.world/`, `:hello.world/`, `hello.world/2`, and `@hello.world/2`

    * `{:dot_call, inside_dot, charlist}` - the context is a dot
      call. This means parentheses or space have been added after the expression.
      where `inside_dot` is either a `{:var, charlist}`, `{:alias, charlist}`,
      `{:module_attribute, charlist}`, `{:unquoted_atom, charlist}` or a `dot`
      itself. If a var is given, it must be a remote call. Examples are
      `Hello.world(`, `:hello.world(`, `Hello.world `, `hello.world(`, `hello.world `,
      and `@hello.world(`

    * `:expr` - may be any expression. Autocompletion may suggest an alias,
      local or var

    * `{:local_or_var, charlist}` - the context is a variable or a local
      (import or local) call, such as `hello_wor`

    * `{:local_arity, charlist}` - the context is a local (import or local)
      arity, such as `hello_world/`

    * `{:local_call, charlist}` - the context is a local (import or local)
      call, such as `hello_world(` and `hello_world `

    * `{:module_attribute, charlist}` - the context is a module attribute, such
      as `@hello_wor`

    * `{:operator, charlist}` (since v1.13.0) - the context is an operator,
      such as `+` or `==`. Note textual operators, such as `when` do not
      appear as operators but rather as `:local_or_var`. `@` is never an
      `:operator` and always a `:module_attribute`

    * `{:operator_arity, charlist}` (since v1.13.0)  - the context is an
      operator arity, which is an operator followed by /, such as `+/`,
      `not/` or `when/`

    * `{:operator_call, charlist}` (since v1.13.0)  - the context is an
      operator call, which is an operator followed by space, such as
      `left + `, `not ` or `x when `

    * `:none` - no context possible

    * `{:unquoted_atom, charlist}` - the context is an unquoted atom. This
      can be any atom or an atom representing a module

  ## Limitations

    * The current algorithm only considers the last line of the input
    * Context does not yet track strings and sigils
    * Arguments of functions calls are not currently recognized

  """
  @doc since: "1.13.0"
  @spec cursor_context(List.Chars.t(), keyword()) ::
          {:alias, charlist}
          | {:dot, inside_dot, charlist}
          | {:dot_arity, inside_dot, charlist}
          | {:dot_call, inside_dot, charlist}
          | :expr
          | {:local_or_var, charlist}
          | {:local_arity, charlist}
          | {:local_call, charlist}
          | {:module_attribute, charlist}
          | {:operator, charlist}
          | {:operator_arity, charlist}
          | {:operator_call, charlist}
          | :none
          | {:unquoted_atom, charlist}
        when inside_dot:
               {:alias, charlist}
               | {:dot, inside_dot, charlist}
               | {:module_attribute, charlist}
               | {:unquoted_atom, charlist}
               | {:var, charlist}
  def cursor_context(fragment, opts \\ [])

  def cursor_context(binary, opts) when is_binary(binary) and is_list(opts) do
    binary =
      case :binary.matches(binary, "\n") do
        [] ->
          binary

        matches ->
          {position, _} = List.last(matches)
          binary_part(binary, position + 1, byte_size(binary) - position - 1)
      end

    binary
    |> String.to_charlist()
    |> :lists.reverse()
    |> codepoint_cursor_context(opts)
    |> elem(0)
  end

  def cursor_context(charlist, opts) when is_list(charlist) and is_list(opts) do
    charlist =
      case charlist |> Enum.chunk_by(&(&1 == ?\n)) |> List.last([]) do
        [?\n | _] -> []
        rest -> rest
      end

    charlist
    |> :lists.reverse()
    |> codepoint_cursor_context(opts)
    |> elem(0)
  end

  def cursor_context(other, opts) when is_list(opts) do
    cursor_context(to_charlist(other), opts)
  end

  @operators '\\<>+-*/:=|&~^%!'
  @starter_punctuation ',([{;'
  @non_starter_punctuation ')]}"\'.$'
  @space '\t\s'
  @trailing_identifier '?!'

  @non_identifier @trailing_identifier ++
                    @operators ++ @starter_punctuation ++ @non_starter_punctuation ++ @space

  @textual_operators ~w(when not and or in)c

  defp codepoint_cursor_context(reverse, _opts) do
    {stripped, spaces} = strip_spaces(reverse, 0)

    case stripped do
      # It is empty
      [] -> {:expr, 0}
      # Token/AST only operators
      [?>, ?= | rest] when rest == [] or hd(rest) != ?: -> {:expr, 0}
      [?>, ?- | rest] when rest == [] or hd(rest) != ?: -> {:expr, 0}
      # Two-digit containers
      [?<, ?< | rest] when rest == [] or hd(rest) != ?< -> {:expr, 0}
      # Ambiguity around :
      [?: | rest] when rest == [] or hd(rest) != ?: -> unquoted_atom_or_expr(spaces)
      # Dots
      [?.] -> {:none, 0}
      [?. | rest] when hd(rest) not in '.:' -> dot(rest, spaces + 1, '')
      # It is a local or remote call with parens
      [?( | rest] -> call_to_cursor_context(strip_spaces(rest, spaces + 1))
      # A local arity definition
      [?/ | rest] -> arity_to_cursor_context(strip_spaces(rest, spaces + 1))
      # Starting a new expression
      [h | _] when h in @starter_punctuation -> {:expr, 0}
      # It is a local or remote call without parens
      rest when spaces > 0 -> call_to_cursor_context({rest, spaces})
      # It is an identifier
      _ -> identifier_to_cursor_context(reverse, 0, false)
    end
  end

  defp strip_spaces([h | rest], count) when h in @space, do: strip_spaces(rest, count + 1)
  defp strip_spaces(rest, count), do: {rest, count}

  defp unquoted_atom_or_expr(0), do: {{:unquoted_atom, ''}, 1}
  defp unquoted_atom_or_expr(_), do: {:expr, 0}

  defp arity_to_cursor_context({reverse, spaces}) do
    case identifier_to_cursor_context(reverse, spaces, true) do
      {{:local_or_var, acc}, count} -> {{:local_arity, acc}, count}
      {{:dot, base, acc}, count} -> {{:dot_arity, base, acc}, count}
      {{:operator, acc}, count} -> {{:operator_arity, acc}, count}
      {_, _} -> {:none, 0}
    end
  end

  defp call_to_cursor_context({reverse, spaces}) do
    case identifier_to_cursor_context(reverse, spaces, true) do
      {{:local_or_var, acc}, count} -> {{:local_call, acc}, count}
      {{:dot, base, acc}, count} -> {{:dot_call, base, acc}, count}
      {{:operator, acc}, count} -> {{:operator_call, acc}, count}
      {_, _} -> {:none, 0}
    end
  end

  defp identifier_to_cursor_context([?., ?., ?: | _], n, _), do: {{:unquoted_atom, '..'}, n + 3}
  defp identifier_to_cursor_context([?., ?., ?. | _], n, _), do: {{:local_or_var, '...'}, n + 3}
  defp identifier_to_cursor_context([?., ?: | _], n, _), do: {{:unquoted_atom, '.'}, n + 2}
  defp identifier_to_cursor_context([?., ?. | _], n, _), do: {{:operator, '..'}, n + 2}

  defp identifier_to_cursor_context(reverse, count, call_op?) do
    case identifier(reverse, count) do
      :none ->
        {:none, 0}

      :operator ->
        operator(reverse, count, [], call_op?)

      {:module_attribute, acc, count} ->
        {{:module_attribute, acc}, count}

      {:unquoted_atom, acc, count} ->
        {{:unquoted_atom, acc}, count}

      {:alias, '.' ++ rest, acc, count} when rest == [] or hd(rest) != ?. ->
        nested_alias(rest, count + 1, acc)

      {:identifier, '.' ++ rest, acc, count} when rest == [] or hd(rest) != ?. ->
        dot(rest, count + 1, acc)

      {:alias, _, acc, count} ->
        {{:alias, acc}, count}

      {:identifier, _, acc, count} when call_op? and acc in @textual_operators ->
        {{:operator, acc}, count}

      {:identifier, _, acc, count} ->
        {{:local_or_var, acc}, count}
    end
  end

  defp identifier([?? | rest], count), do: check_identifier(rest, count + 1, [??])
  defp identifier([?! | rest], count), do: check_identifier(rest, count + 1, [?!])
  defp identifier(rest, count), do: check_identifier(rest, count, [])

  defp check_identifier([h | t], count, acc) when h not in @non_identifier,
    do: rest_identifier(t, count + 1, [h | acc])

  defp check_identifier(_, _, _), do: :operator

  defp rest_identifier([h | rest], count, acc) when h not in @non_identifier do
    rest_identifier(rest, count + 1, [h | acc])
  end

  defp rest_identifier(rest, count, [?@ | acc]) do
    case tokenize_identifier(rest, count, acc) do
      {:identifier, _rest, acc, count} -> {:module_attribute, acc, count}
      :none when acc == [] -> {:module_attribute, '', count}
      _ -> :none
    end
  end

  defp rest_identifier([?: | rest], count, acc) when rest == [] or hd(rest) != ?: do
    case String.Tokenizer.tokenize(acc) do
      {_, _, [], _, _, _} -> {:unquoted_atom, acc, count + 1}
      _ -> :none
    end
  end

  defp rest_identifier([?? | _], _count, _acc) do
    :none
  end

  defp rest_identifier(rest, count, acc) do
    tokenize_identifier(rest, count, acc)
  end

  defp tokenize_identifier(rest, count, acc) do
    case String.Tokenizer.tokenize(acc) do
      # Not actually an atom cause rest is not a :
      {:atom, _, _, _, _, _} ->
        :none

      # Aliases must be ascii only
      {:alias, _, _, _, false, _} ->
        :none

      {kind, _, [], _, _, extra} ->
        if ?@ in extra do
          :none
        else
          {rest, count} = strip_spaces(rest, count)
          {kind, rest, acc, count}
        end

      _ ->
        :none
    end
  end

  defp nested_alias(rest, count, acc) do
    {rest, count} = strip_spaces(rest, count)

    case identifier_to_cursor_context(rest, count, true) do
      {{:alias, prev}, count} -> {{:alias, prev ++ '.' ++ acc}, count}
      _ -> {:none, 0}
    end
  end

  defp dot(rest, count, acc) do
    {rest, count} = strip_spaces(rest, count)

    case identifier_to_cursor_context(rest, count, true) do
      {{:local_or_var, var}, count} -> {{:dot, {:var, var}, acc}, count}
      {{:unquoted_atom, _} = prev, count} -> {{:dot, prev, acc}, count}
      {{:alias, _} = prev, count} -> {{:dot, prev, acc}, count}
      {{:dot, _, _} = prev, count} -> {{:dot, prev, acc}, count}
      {{:module_attribute, _} = prev, count} -> {{:dot, prev, acc}, count}
      {_, _} -> {:none, 0}
    end
  end

  defp operator([h | rest], count, acc, call_op?) when h in @operators do
    operator(rest, count + 1, [h | acc], call_op?)
  end

  defp operator(rest, count, acc, call_op?) when acc in ~w(^^ ~~ ~)c do
    {rest, dot_count} = strip_spaces(rest, count)

    cond do
      call_op? ->
        {:none, 0}

      match?([?. | rest] when rest == [] or hd(rest) != ?., rest) ->
        dot(tl(rest), dot_count + 1, acc)

      true ->
        {{:operator, acc}, count}
    end
  end

  defp operator(rest, count, acc, _call_op?) do
    case :elixir_tokenizer.tokenize(acc, 1, 1, []) do
      {:ok, _, [{:atom, _, _}]} ->
        {{:unquoted_atom, tl(acc)}, count}

      {:ok, _, [{_, _, op}]} ->
        {rest, dot_count} = strip_spaces(rest, count)

        cond do
          Code.Identifier.unary_op(op) == :error and Code.Identifier.binary_op(op) == :error ->
            :none

          match?([?. | rest] when rest == [] or hd(rest) != ?., rest) ->
            dot(tl(rest), dot_count + 1, acc)

          true ->
            {{:operator, acc}, count}
        end

      _ ->
        {:none, 0}
    end
  end

  @doc """
  Receives a string and returns the surround context.

  This function receives a string with an Elixir code fragment
  and a `position`. It returns a map containing the beginning
  and ending of the expression alongside its context, or `:none`
  if there is nothing with a known context.

  The difference between `cursor_context/2` and `surround_context/3`
  is that the former assumes the expression in the code fragment
  is incomplete. For example, `do` in `cursor_context/2` may be
  a keyword or a variable or a local call, while `surround_context/3`
  assumes the expression in the code fragment is complete, therefore
  `do` would always be a keyword.

  The `position` contains both the `line` and `column`, both starting
  with the index of 1. The column must preceed the surrounding expression.
  For example, the expression `foo`, will return something for the columns
  1, 2, and 3, but not 4:

      foo
      ^ column 1

      foo
       ^ column 2

      foo
        ^ column 3

      foo
         ^ column 4

  The returned map contains the column the expression starts and the
  first column after the expression ends.

  This function builds on top of `cursor_context/2`. Therefore
  it also provides a best-effort detection and may not be accurate
  under all circumstances. See the "Return values" section for more
  information on the available contexts as well as the "Limitations"
  section.

  ## Examples

      iex> Code.Fragment.surround_context("foo", {1, 1})
      %{begin: {1, 1}, context: {:local_or_var, 'foo'}, end: {1, 4}}

  ## Differences to `cursor_context/2`

  In contrast to `cursor_context/2`, `surround_context/3` does not
  return `dot_call`/`dot_arity` nor `operator_call`/`operator_arity`
  contexts because they should behave the same as `dot` and `operator`
  respectively in complete expressions.

  On the other hand, it does make a distinction between `local_call`/
  `local_arity` to `local_or_var`, since the latter can be a local or
  variable.

  Also note that `@` when not followed by any identifier is returned
  as `{:operator, '@'}`, while it is a `{:module_attribute, ''}` in
  `cursor_context/3`. Once again, this happens because `surround_context/3`
  assumes the expression is complete, while `cursor_context/2` does not.
  """
  @doc since: "1.13.0"
  @spec surround_context(List.Chars.t(), position(), keyword()) ::
          %{begin: position, end: position, context: context} | :none
        when context:
               {:alias, charlist}
               | {:dot, inside_dot, charlist}
               | {:local_or_var, charlist}
               | {:local_arity, charlist}
               | {:local_call, charlist}
               | {:module_attribute, charlist}
               | {:operator, charlist}
               | {:unquoted_atom, charlist},
             inside_dot:
               {:alias, charlist}
               | {:dot, inside_dot, charlist}
               | {:module_attribute, charlist}
               | {:unquoted_atom, charlist}
               | {:var, charlist}
  def surround_context(fragment, position, options \\ [])

  def surround_context(binary, {line, column}, opts) when is_binary(binary) do
    binary
    |> String.split("\n")
    |> Enum.at(line - 1, '')
    |> String.to_charlist()
    |> position_surround_context(line, column, opts)
  end

  def surround_context(charlist, {line, column}, opts) when is_list(charlist) do
    charlist
    |> :string.split('\n', :all)
    |> Enum.at(line - 1, '')
    |> position_surround_context(line, column, opts)
  end

  def surround_context(other, position, opts) do
    surround_context(to_charlist(other), position, opts)
  end

  defp position_surround_context(charlist, line, column, opts)
       when is_integer(line) and line >= 1 and is_integer(column) and column >= 1 do
    {reversed_pre, post} = string_reverse_at(charlist, column - 1, [])
    {reversed_pre, post} = adjust_position(reversed_pre, post)

    case take_identifier(post, []) do
      {_, [], _} ->
        maybe_operator(reversed_pre, post, line, opts)

      {:identifier, reversed_post, rest} ->
        {rest, _} = strip_spaces(rest, 0)
        reversed = reversed_post ++ reversed_pre

        case codepoint_cursor_context(reversed, opts) do
          {{:alias, acc}, offset} ->
            build_surround({:alias, acc}, reversed, line, offset)

          {{:dot, _, [_ | _]} = dot, offset} ->
            build_surround(dot, reversed, line, offset)

          {{:local_or_var, acc}, offset} when hd(rest) == ?( ->
            build_surround({:local_call, acc}, reversed, line, offset)

          {{:local_or_var, acc}, offset} when hd(rest) == ?/ ->
            build_surround({:local_arity, acc}, reversed, line, offset)

          {{:local_or_var, acc}, offset} when acc in @textual_operators ->
            build_surround({:operator, acc}, reversed, line, offset)

          {{:local_or_var, acc}, offset} when acc not in ~w(do end after else catch rescue)c ->
            build_surround({:local_or_var, acc}, reversed, line, offset)

          {{:module_attribute, ''}, offset} ->
            build_surround({:operator, '@'}, reversed, line, offset)

          {{:module_attribute, acc}, offset} ->
            build_surround({:module_attribute, acc}, reversed, line, offset)

          {{:unquoted_atom, acc}, offset} ->
            build_surround({:unquoted_atom, acc}, reversed, line, offset)

          _ ->
            maybe_operator(reversed_pre, post, line, opts)
        end

      {:alias, reversed_post, _rest} ->
        reversed = reversed_post ++ reversed_pre

        case codepoint_cursor_context(reversed, opts) do
          {{:alias, acc}, offset} ->
            build_surround({:alias, acc}, reversed, line, offset)

          _ ->
            :none
        end
    end
  end

  defp maybe_operator(reversed_pre, post, line, opts) do
    case take_operator(post, []) do
      {[], _rest} ->
        :none

      {reversed_post, _rest} ->
        reversed = reversed_post ++ reversed_pre

        case codepoint_cursor_context(reversed, opts) do
          {{:operator, acc}, offset} ->
            build_surround({:operator, acc}, reversed, line, offset)

          {{:dot, _, [_ | _]} = dot, offset} ->
            build_surround(dot, reversed, line, offset)

          _ ->
            :none
        end
    end
  end

  defp build_surround(context, reversed, line, offset) do
    {post, reversed_pre} = enum_reverse_at(reversed, offset, [])
    pre = :lists.reverse(reversed_pre)
    pre_length = :string.length(pre) + 1

    %{
      context: context,
      begin: {line, pre_length},
      end: {line, pre_length + :string.length(post)}
    }
  end

  defp take_identifier([h | t], acc) when h in @trailing_identifier,
    do: {:identifier, [h | acc], t}

  defp take_identifier([h | t], acc) when h not in @non_identifier,
    do: take_identifier(t, [h | acc])

  defp take_identifier(rest, acc) do
    with {[?. | t], _} <- strip_spaces(rest, 0),
         {[h | _], _} when h in ?A..?Z <- strip_spaces(t, 0) do
      take_alias(rest, acc)
    else
      _ -> {:identifier, acc, rest}
    end
  end

  defp take_alias([h | t], acc) when h not in @non_identifier,
    do: take_alias(t, [h | acc])

  defp take_alias(rest, acc) do
    with {[?. | t], acc} <- move_spaces(rest, acc),
         {[h | t], acc} when h in ?A..?Z <- move_spaces(t, [?. | acc]) do
      take_alias(t, [h | acc])
    else
      _ -> {:alias, acc, rest}
    end
  end

  defp take_operator([h | t], acc) when h in @operators, do: take_operator(t, [h | acc])
  defp take_operator([h | t], acc) when h == ?., do: take_operator(t, [h | acc])
  defp take_operator(rest, acc), do: {acc, rest}

  # Unquoted atom handling
  defp adjust_position(reversed_pre, [?: | post])
       when hd(post) != ?: and (reversed_pre == [] or hd(reversed_pre) != ?:) do
    {[?: | reversed_pre], post}
  end

  # Dot handling
  defp adjust_position(reversed_pre, post) do
    case move_spaces(post, reversed_pre) do
      # If we are between spaces and a dot, move past the dot
      {[?. | post], reversed_pre} when hd(post) != ?. and hd(reversed_pre) != ?. ->
        {post, reversed_pre} = move_spaces(post, [?. | reversed_pre])
        {reversed_pre, post}

      _ ->
        case strip_spaces(reversed_pre, 0) do
          # If there is a dot to our left, make sure to move to the first character
          {[?. | rest], _} when rest == [] or hd(rest) not in '.:' ->
            {post, reversed_pre} = move_spaces(post, reversed_pre)
            {reversed_pre, post}

          _ ->
            {reversed_pre, post}
        end
    end
  end

  defp move_spaces([h | t], acc) when h in @space, do: move_spaces(t, [h | acc])
  defp move_spaces(t, acc), do: {t, acc}

  defp string_reverse_at(charlist, 0, acc), do: {acc, charlist}

  defp string_reverse_at(charlist, n, acc) do
    case :unicode_util.gc(charlist) do
      [gc | cont] when is_integer(gc) -> string_reverse_at(cont, n - 1, [gc | acc])
      [gc | cont] when is_list(gc) -> string_reverse_at(cont, n - 1, :lists.reverse(gc, acc))
      [] -> {[], acc}
    end
  end

  defp enum_reverse_at([h | t], n, acc) when n > 0, do: enum_reverse_at(t, n - 1, [h | acc])
  defp enum_reverse_at(rest, _, acc), do: {acc, rest}
end
