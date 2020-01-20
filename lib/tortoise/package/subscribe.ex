defmodule Tortoise.Package.Subscribe do
  @moduledoc false

  @opcode 8

  # @allowed_properties [:subscription_identifier, :user_property]

  alias Tortoise.Package

  @type qos :: 0 | 1 | 2
  @type topic :: {binary(), topic_opts}
  @type topic_opts :: [
          {:qos, qos},
          {:no_local, boolean()},
          {:retain_as_published, boolean()},
          {:retain_handling, 0 | 1 | 2}
        ]
  @type topics :: [topic]

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            topics: topics(),
            properties: [
              {:subscription_identifier, 0x1..0xFFFFFFF},
              {:user_property, {String.t(), String.t()}}
            ]
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0b0010},
            identifier: nil,
            topics: [],
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0b0010::4, length_prefixed_payload::binary>>) do
    payload = drop_length(length_prefixed_payload)
    <<identifier::big-integer-size(16), rest::binary>> = payload
    {properties, topics} = Package.parse_variable_length(rest)

    %__MODULE__{
      identifier: identifier,
      topics: decode_topics(topics),
      properties: Package.Properties.decode(properties)
    }
  end

  defp drop_length(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  defp decode_topics(<<>>), do: []

  defp decode_topics(<<length::big-integer-size(16), rest::binary>>) do
    <<
      topic::binary-size(length),
      # reserved
      0::2,
      retain_handling::2,
      retain_as_published::1,
      no_local::1,
      qos::2,
      rest::binary
    >> = rest

    opts = [
      qos: qos,
      no_local: no_local == 1,
      retain_as_published: retain_as_published == 1,
      retain_handling: retain_handling
    ]

    [{topic, opts}] ++ decode_topics(rest)
  end

  # PROTOCOLS ==========================================================
  defimpl Tortoise.Encodable do
    def encode(
          %Package.Subscribe{
            identifier: identifier,
            # a valid subscribe package has at least one topic/opts pair
            topics: [{<<_topic_filter::binary>>, opts} | _]
          } = t
        )
        when identifier in 0x0001..0xFFFF and is_list(opts) do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16)>>,
          Package.Properties.encode(t.properties),
          encode_topics(t.topics)
        ])
      ]
    end

    defp encode_topics(topics) do
      Enum.map(topics, fn {topic, opts} ->
        qos = Keyword.get(opts, :qos, 0)
        no_local = Keyword.get(opts, :no_local, false)
        retain_as_published = Keyword.get(opts, :retain_as_published, false)
        retain_handling = Keyword.get(opts, :retain_handling, 1)

        [
          Package.length_encode(topic),
          <<0::2, retain_handling::2, flag(retain_as_published)::1, flag(no_local)::1, qos::2>>
        ]
      end)
    end

    defp flag(f) when f in [0, nil, false], do: 0
    defp flag(_), do: 1
  end

  defimpl Enumerable do
    def reduce(%Package.Subscribe{topics: topics}, acc, fun) do
      Enumerable.List.reduce(topics, acc, fun)
    end

    def member?(%Package.Subscribe{topics: topics}, {<<topic::binary>>, qos})
        when is_integer(qos) do
      matcher = fn {current_topic, opts} ->
        topic == current_topic && opts[:qos] == qos
      end

      case Enum.find(topics, matcher) do
        nil -> {:ok, false}
        _ -> {:ok, true}
      end
    end

    def member?(%Package.Subscribe{topics: topics}, value) do
      {:ok, Enum.member?(topics, value)}
    end

    def count(%Package.Subscribe{topics: topics}) do
      {:ok, Enum.count(topics)}
    end

    def slice(_) do
      # todo
      {:error, __MODULE__}
    end
  end

  defimpl Collectable do
    def into(%Package.Subscribe{topics: current_topics} = source) do
      {current_topics,
       fn
         acc, {:cont, {<<topic::binary>>, opts}} when is_list(opts) ->
           List.keystore(acc, topic, 0, {topic, opts})

         acc, {:cont, {<<topic::binary>>, qos}} when qos in 0..2 ->
           List.keystore(acc, topic, 0, {topic, qos: qos})

         acc, {:cont, <<topic::binary>>} ->
           List.keystore(acc, topic, 0, {topic, qos: 0})

         acc, :done ->
           %{source | topics: acc}

         _, :halt ->
           :ok
       end}
    end
  end
end
