defprotocol Tortoise.Generatable do
  @moduledoc false

  # TODO add spec
  def generate(data)
end

if Code.ensure_loaded?(StreamData) do
  defmodule Tortoise.Generatable.Topic do
    import StreamData

    # "/" is a valid topic, becomes ["", ""] in tortoise, which is a
    # special case because topic levels are not allowed to be empty:
    # they must be a string of at least one character. It is also
    # allowed to start a topic with a slash "/foo" which is different
    # from "foo". In tortoise, when the user is given the topic
    # levels, the former if represented as `["", "foo"]`.

    @doc """
    Generate a random MQTT topic
    """
    def gen_topic() do
      # generate a list of nils that will get replaced by topic level
      # generators
      bind(list_of(nil), &gen_topic/1)
    end

    @doc """
    Generate a topic based on an input

    TODO fix this documentation
    """
    # Let the smallest element that can be created be "/", which in
    # out internal representation is represented as `["", ""]`.
    def gen_topic([]), do: constant(["", ""])

    # short circuit one level long topics
    def gen_topic([topic_level]) do
      fixed_list([gen_topic_level(topic_level)])
    end

    # from now on we are dealing with lists of length > 1
    def gen_topic([_ | _] = input) do
      bind(constant(input), fn
        [nil | topic_list] ->
          fixed_list([
            frequency([
              # the first topic level is allowed to be empty which
              # will translate into a topic that starts with a slash
              # ("/foo", which is different from "foo")
              {4, gen_topic_level(nil)},
              {1, constant("")}
            ])
            | for(topic_level <- topic_list, do: gen_topic_level(topic_level))
          ])

        topic_list ->
          fixed_list(for topic_level <- topic_list, do: gen_topic_level(topic_level))
      end)
    end

    # generate the topic level names
    defp gen_topic_level(nil) do
      bind(string(:ascii, min_length: 1), fn topic_level ->
        constant(String.replace(topic_level, ["#", "+", "/"], "_"))
      end)
    end

    defp gen_topic_level(%StreamData{} = generator), do: generator
    defp gen_topic_level(<<literal::binary>>), do: constant(literal)

    @doc """
    Generate a random topic filter
    """
    def gen_filter() do
      bind(list_of(nil), &gen_filter/1)
    end

    @doc """
    Generate a topic filter based on a topic

    The resulting topic filter will be one that matches the given
    topic, so `["foo", "bar"]` will result in topic filters such as
    `["foo", "+"]`, `["#"]`, `["+", "#"]`, etc.
    """
    def gen_filter(input) do
      gen_topic(input)
      |> bind(&maybe_add_multi_level_filter/1)
      |> bind(&mutate_topic_levels/1)
    end

    defp maybe_add_multi_level_filter(topic_levels) do
      frequency([
        {4, constant(topic_levels)},
        {1, bind(constant(topic_levels), &add_multi_level_filter/1)}
      ])
    end

    defp add_multi_level_filter([_ | _] = topic_list) do
      start = length(topic_list) * -1

      bind(integer(start..-1), fn position ->
        constant(Enum.drop(topic_list, position) ++ ["#"])
      end)
    end

    defp mutate_topic_levels(topic_levels) do
      fixed_list(for topic_level <- topic_levels, do: do_mutate_topic_level(topic_level))
    end

    defp do_mutate_topic_level("+"), do: constant("+")
    defp do_mutate_topic_level("#"), do: constant("#")

    defp do_mutate_topic_level(topic_level) do
      frequency([
        {1, constant("+")},
        {2, constant(topic_level)}
      ])
    end
  end
end
