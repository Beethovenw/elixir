defmodule ExUnit.Diff do
  @moduledoc false

  @doc """
  Returns an edit script representing the difference between `left` and `right`.

  Returns `nil` if they are not the same data type,
  or if the given data type is not supported.
  """
  def script(left, right)

  def script(term, term)
      when is_binary(term) or is_number(term)
      when is_map(term) or is_list(term) or is_tuple(term) do
    [eq: inspect(term)]
  end

  # Binaries
  def script(left, right) when is_binary(left) and is_binary(right) do
    if String.printable?(left) and String.printable?(right) do
      script_string(left, right, ?\")
    end
  end

  # Structs
  def script(%name{} = left, %name{} = right) do
    if Inspect.impl_for(left) != Inspect.Any do
      inspect_left = inspect(left)
      inspect_right = inspect(right)

      if inspect_left != inspect_right do
        script_string(inspect_left, inspect_right)
      else
        script_struct(left, right, name)
      end
    else
      script_struct(left, right, name)
    end
  end

  # Maps
  def script(%{} = left, %{} = right) do
    if match?(%_{}, left) or match?(%_{}, right) do
      nil
    else
      script_map(left, right, "")
    end
  end

  # Char lists and lists
  def script(left, right) when is_list(left) and is_list(right) do
    if List.ascii_printable?(left) and List.ascii_printable?(right) do
      script_string(List.to_string(left), List.to_string(right), ?')
    else
      keywords? = Inspect.List.keyword?(left) and Inspect.List.keyword?(right)
      script = script_list(left, right, keywords?)
      [{:eq, "["}, script, {:eq, "]"}]
    end
  end

  # Numbers
  def script(left, right)
      when is_integer(left) and is_integer(right)
      when is_float(left) and is_float(right) do
    script_string(inspect(left), inspect(right))
  end

  # Tuples
  def script(left, right) when is_tuple(left) and is_tuple(right) do
    script =
      script_list(
        Tuple.to_list(left),
        tuple_size(left),
        Tuple.to_list(right),
        tuple_size(right),
        false
      )

    [{:eq, "{"}, script, {:eq, "}"}]
  end

  def script(_left, _right), do: nil

  defp script_string(string1, string2, token) do
    length1 = String.length(string1)
    length2 = String.length(string2)

    if bag_distance(string1, string2) / max(length1, length2) <= 0.6 do
      {escaped1, _} = Code.Identifier.escape(string1, token)
      {escaped2, _} = Code.Identifier.escape(string2, token)
      string1 = IO.iodata_to_binary(escaped1)
      string2 = IO.iodata_to_binary(escaped2)
      [{:eq, <<token>>}, script_string(string1, string2), {:eq, <<token>>}]
    end
  end

  defp script_string(string1, string2) do
    String.myers_difference(string1, string2)
  end

  # The algorithm is outlined in the
  # "String Matching with Metric Trees Using an Approximate Distance"
  # paper by Ilaria Bartolini, Paolo Ciaccia, and Marco Patella.
  defp bag_distance(string1, string2) do
    bag1 = string_to_bag(string1)
    bag2 = string_to_bag(string2)

    diff1 = bag_difference(bag1, bag2)
    diff2 = bag_difference(bag2, bag1)

    max(diff1, diff2)
  end

  defp string_to_bag(string) do
    string_to_bag(string, %{}, &(&1 + 1))
  end

  defp string_to_bag(string, bag, fun) do
    case String.next_grapheme(string) do
      {char, rest} ->
        bag = Map.update(bag, char, 1, fun)
        string_to_bag(rest, bag, fun)

      nil ->
        bag
    end
  end

  defp bag_difference(bag1, bag2) do
    Enum.reduce(bag1, 0, fn {char, count1}, sum ->
      case Map.fetch(bag2, char) do
        {:ok, count2} ->
          sum + max(count1 - count2, 0)

        :error ->
          sum + count1
      end
    end)
  end

  defp length_and_slice_proper_part([item | rest], length, result) do
    length_and_slice_proper_part(rest, length + 1, [item | result])
  end

  defp length_and_slice_proper_part([], length, result) do
    {length, Enum.reverse(result), []}
  end

  defp length_and_slice_proper_part(item, length, result) do
    {length, Enum.reverse(result), [item]}
  end

  defp script_list(list1, list2, keywords?) do
    {length1, list1, improper_rest1} = length_and_slice_proper_part(list1, 0, [])
    {length2, list2, improper_rest2} = length_and_slice_proper_part(list2, 0, [])

    script = script_list(list1, length1, list2, length2, keywords?)

    case {improper_rest1, improper_rest2} do
      {[item1], [item2]} ->
        [script, [eq: " | "] ++ script_inner(item1, item2)]

      {[item1], []} ->
        [script, del: " | " <> inspect(item1)]

      {[], [item2]} ->
        [script, ins: " | " <> inspect(item2)]

      {[], []} ->
        script
    end
  end

  defp script_list(list1, length1, list2, length2, keywords?) do
    case script_subset_list(list1, list2) do
      {:ok, script} ->
        format_each_fragment(script, [], keywords?)

      :error ->
        initial_path = {0, 0, list1, list2, []}

        find_script(0, length1 + length2, [initial_path], keywords?)
        |> format_each_fragment([], keywords?)
    end
  end

  defp script_subset_list(list1, list2) do
    case find_subset_list(list1, list2, []) do
      {subset, rest1, rest2} ->
        {:ok, wrap_in(:eq, Enum.reverse(subset)) ++ wrap_in(:del, rest1) ++ wrap_in(:ins, rest2)}

      nil ->
        case find_subset_list(Enum.reverse(list1), Enum.reverse(list2), []) do
          {subset, rest1, rest2} ->
            {:ok,
             wrap_in(:del, Enum.reverse(rest1)) ++
               wrap_in(:ins, Enum.reverse(rest2)) ++ wrap_in(:eq, subset)}

          nil ->
            :error
        end
    end
  end

  defp find_subset_list([item | rest1], [item | rest2], subset) do
    find_subset_list(rest1, rest2, [item | subset])
  end

  defp find_subset_list(rest1, rest2, subset) when rest1 == [] or rest2 == [] do
    {subset, rest1, rest2}
  end

  defp find_subset_list(_subset, _rest1, _rest2), do: nil

  defp wrap_in(_tag, []), do: []
  defp wrap_in(tag, items), do: [{tag, items}]

  defp format_each_fragment([{:diff, script}], [], _keywords?) do
    script
  end

  defp format_each_fragment([{kind, elems}], [], keywords?) do
    [format_fragment(kind, elems, keywords?)]
  end

  defp format_each_fragment([_, _] = fragments, acc, keywords?) do
    result =
      case fragments do
        [del: elems1, ins: elems2] ->
          [
            format_fragment(:del, elems1, keywords?),
            format_fragment(:ins, elems2, keywords?)
          ]

        [{kind1, elems1}, {kind2, elems2}] ->
          [
            format_fragment(kind1, elems1, keywords?),
            script_comma(kind1, kind2),
            format_fragment(kind2, elems2, keywords?)
          ]
      end

    Enum.reverse(acc, result)
  end

  defp format_each_fragment([{:diff, script} | rest], acc, keywords?) do
    format_each_fragment(rest, [{:eq, ", "}, script | acc], keywords?)
  end

  defp format_each_fragment([{kind, elems} | rest], acc, keywords?) do
    new_acc = [script_comma(kind, kind), format_fragment(kind, elems, keywords?) | acc]
    format_each_fragment(rest, new_acc, keywords?)
  end

  defp script_comma(:diff, :diff), do: {:eq, ", "}
  defp script_comma(:diff, kind), do: {kind, ", "}
  defp script_comma(kind, :diff), do: {kind, ", "}
  defp script_comma(:eq, kind), do: {kind, ", "}
  defp script_comma(kind, :eq), do: {kind, ", "}
  defp script_comma(kind, _), do: {kind, ", "}

  defp format_fragment(:diff, script, _) do
    script
  end

  defp format_fragment(kind, elems, keywords?) do
    formatter = fn
      {key, val} when keywords? ->
        format_key_value(key, val, true)

      elem ->
        inspect(elem)
    end

    {kind, Enum.map_join(elems, ", ", formatter)}
  end

  defp find_script(envelope, max, paths, keywords?) do
    case each_diagonal(-envelope, envelope, paths, [], keywords?) do
      {:done, edits} ->
        compact_reverse(edits, [])

      {:next, paths} ->
        find_script(envelope + 1, max, paths, keywords?)
    end
  end

  defp compact_reverse([], acc), do: acc

  defp compact_reverse([{:diff, _} = fragment | rest], acc),
    do: compact_reverse(rest, [fragment | acc])

  defp compact_reverse([{kind, char} | rest], [{kind, chars} | acc]),
    do: compact_reverse(rest, [{kind, [char | chars]} | acc])

  defp compact_reverse([{kind, char} | rest], acc),
    do: compact_reverse(rest, [{kind, [char]} | acc])

  defp each_diagonal(diag, limit, _paths, next_paths, _keywords?) when diag > limit do
    {:next, Enum.reverse(next_paths)}
  end

  defp each_diagonal(diag, limit, paths, next_paths, keywords?) do
    {path, rest} = proceed_path(diag, limit, paths, keywords?)

    with {:cont, path} <- follow_snake(path) do
      each_diagonal(diag + 2, limit, rest, [path | next_paths], keywords?)
    end
  end

  defp proceed_path(0, 0, [path], _keywords?), do: {path, []}

  defp proceed_path(diag, limit, [path | _] = paths, keywords?) when diag == -limit do
    {move_down(path, keywords?), paths}
  end

  defp proceed_path(diag, limit, [path], keywords?) when diag == limit do
    {move_right(path, keywords?), []}
  end

  defp proceed_path(_diag, _limit, [path1, path2 | rest], keywords?) do
    if elem(path1, 1) > elem(path2, 1) do
      {move_right(path1, keywords?), [path2 | rest]}
    else
      {move_down(path2, keywords?), [path2 | rest]}
    end
  end

  defp script_keyword_inner({key, val1}, {key, val2}, true),
    do: [{:eq, format_key(key, true)}, script_inner(val1, val2)]

  defp script_keyword_inner(_pair1, _pair2, true),
    do: nil

  defp script_keyword_inner(elem1, elem2, false),
    do: script(elem1, elem2)

  defp move_right({x, x, [elem1 | rest1] = list1, [elem2 | rest2], edits}, keywords?) do
    if result = script_keyword_inner(elem1, elem2, keywords?) do
      {x + 1, x + 1, rest1, rest2, [{:diff, result} | edits]}
    else
      {x + 1, x, list1, rest2, [{:ins, elem2} | edits]}
    end
  end

  defp move_right({x, y, list1, [elem | rest], edits}, _keywords?) do
    {x + 1, y, list1, rest, [{:ins, elem} | edits]}
  end

  defp move_right({x, y, list1, [], edits}, _keywords?) do
    {x + 1, y, list1, [], edits}
  end

  defp move_down({x, x, [elem1 | rest1], [elem2 | rest2] = list2, edits}, keywords?) do
    if result = script_keyword_inner(elem1, elem2, keywords?) do
      {x + 1, x + 1, rest1, rest2, [{:diff, result} | edits]}
    else
      {x, x + 1, rest1, list2, [{:del, elem1} | edits]}
    end
  end

  defp move_down({x, y, [elem | rest], list2, edits}, _keywords?) do
    {x, y + 1, rest, list2, [{:del, elem} | edits]}
  end

  defp move_down({x, y, [], list2, edits}, _keywords?) do
    {x, y + 1, [], list2, edits}
  end

  defp follow_snake({x, y, [elem | rest1], [elem | rest2], edits}) do
    follow_snake({x + 1, y + 1, rest1, rest2, [{:eq, elem} | edits]})
  end

  defp follow_snake({_x, _y, [], [], edits}) do
    {:done, edits}
  end

  defp follow_snake(path) do
    {:cont, path}
  end

  defp script_map(left, right, name) do
    {surplus, altered, missing, same} = map_difference(left, right)

    keywords? =
      Inspect.List.keyword?(surplus) and Inspect.List.keyword?(altered) and
        Inspect.List.keyword?(missing) and Inspect.List.keyword?(same)

    result =
      Enum.reduce(missing, [], fn {key, val}, acc ->
        map_pair = format_key_value(key, val, keywords?)
        [[ins: ", ", ins: map_pair] | acc]
      end)

    result =
      if same == [] and altered == [] and missing != [] and surplus != [] do
        [[_ | elem_diff] | rest] = result
        [elem_diff | rest]
      else
        result
      end

    result =
      Enum.reduce(surplus, result, fn {key, val}, acc ->
        map_pair = format_key_value(key, val, keywords?)
        [[del: ", ", del: map_pair] | acc]
      end)

    result =
      Enum.reduce(altered, result, fn {key, {val1, val2}}, acc ->
        value_diff = script_inner(val1, val2)
        [[{:eq, ", "}, {:eq, format_key(key, keywords?)}, value_diff] | acc]
      end)

    result =
      Enum.reduce(same, result, fn {key, val}, acc ->
        map_pair = format_key_value(key, val, keywords?)
        [[eq: ", ", eq: map_pair] | acc]
      end)

    [[_ | elem_diff] | rest] = result
    [{:eq, "%" <> name <> "{"}, [elem_diff | rest], {:eq, "}"}]
  end

  defp script_struct(left, right, name) do
    left = Map.from_struct(left)
    right = Map.from_struct(right)
    script_map(left, right, inspect(name))
  end

  defp map_difference(map1, map2) do
    {surplus, altered, same} =
      Enum.reduce(map1, {[], [], []}, fn {key, val1}, {surplus, altered, same} ->
        case Map.fetch(map2, key) do
          {:ok, ^val1} ->
            {surplus, altered, [{key, val1} | same]}

          {:ok, val2} ->
            {surplus, [{key, {val1, val2}} | altered], same}

          :error ->
            {[{key, val1} | surplus], altered, same}
        end
      end)

    missing =
      Enum.reduce(map2, [], fn {key, _} = pair, acc ->
        if Map.has_key?(map1, key), do: acc, else: [pair | acc]
      end)

    {surplus, altered, missing, same}
  end

  defp format_key(key, false) do
    inspect(key) <> " => "
  end

  defp format_key(key, true) when is_nil(key) or is_boolean(key) do
    inspect(key) <> ": "
  end

  defp format_key(key, true) do
    ":" <> result = inspect(key)
    result <> ": "
  end

  defp format_key_value(key, value, keyword?) do
    format_key(key, keyword?) <> inspect(value)
  end

  defp script_inner(term, term) do
    [eq: inspect(term)]
  end

  defp script_inner(left, right) do
    if result = script(left, right) do
      result
    else
      [del: inspect(left), ins: inspect(right)]
    end
  end
end
