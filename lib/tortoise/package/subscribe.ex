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
          } = t,
          _opts
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

  if Code.ensure_loaded?(StreamData) do
    defimpl Tortoise.Generatable do
      import StreamData

      alias Tortoise.Generatable.Topic

      def generate(%type{__META__: _meta} = package) do
        values = package |> Map.from_struct()

        fixed_list(Enum.map(values, &constant(&1)))
        |> bind(&gen_identifier/1)
        |> bind(&gen_topics/1)
        |> bind(&gen_topic_opts/1)
        |> bind(&gen_properties/1)
        |> bind(&fixed_map([{:__struct__, type} | for({k, v} <- &1, do: {k, constant(v)})]))
      end

      defp gen_identifier(values) do
        case Keyword.pop(values, :identifier) do
          {nil, values} ->
            fixed_list([
              {constant(:identifier), integer(1..0xFFFF)}
              | Enum.map(values, &constant(&1))
            ])

          {id, _} when is_integer(id) and id in 1..0xFFFF ->
            constant(values)
        end
      end

      defp gen_topics(values) do
        case Keyword.pop(values, :topics) do
          {nil, values} ->
            fixed_list([
              {
                :topics,
                list_of(
                  {gen_topic_filter(), constant(nil)},
                  max_length: 5,
                  min_length: 1
                )
              }
              | Enum.map(values, &constant(&1))
            ])

          {[_ | _] = topics, values} ->
            [
              {:topics,
               fixed_list(
                 Enum.map(topics, fn
                   nil ->
                     {gen_topic_filter(), constant([])}

                   {nil, opts} ->
                     {gen_topic_filter(), constant(opts)}

                   %StreamData{} = generator ->
                     bind(generator, fn
                       {<<_::binary>>, opts} = result when is_list(opts) or is_nil(opts) ->
                         # result seems fine, pass it on
                         constant(result)

                       faulty_return ->
                         raise ArgumentError, """
                         Faulty result from user specified topic generator #{inspect(generator)}

                         The generator should return a tuple with two elements, where the first is a binary, and the second is a `nil` or a list. Instead the generator returned:

                           #{inspect(faulty_return)}

                         """
                     end)

                   {%StreamData{} = generator, opts} ->
                     {generator, constant(opts)}

                   {<<_::binary>>, _} = otherwise ->
                     constant(otherwise)
                 end)
               )}
              | Enum.map(values, &constant(&1))
            ]
            |> fixed_list()
        end
      end

      defp gen_topic_filter() do
        bind(Topic.gen_filter(), &constant(Enum.join(&1, "/")))
      end

      # create random options for the topics in the topic list
      defp gen_topic_opts(values) do
        # at this point in time we should have a list of topics!
        {[{_, _} | _] = topics, values} = Keyword.pop(values, :topics)

        topics_with_opts =
          Enum.map(topics, fn {topic_filter, opts} ->
            opts = opts || []

            {
              constant(topic_filter),
              # notice that while the order of options shouldn't
              # matter, it kind of does in the context of the prop
              # tests for encoding and decoding the subscribe
              # packages, as the keyword lists will get compared for
              # equality
              fixed_list([
                do_get_opts(opts, :qos, integer(0..2)),
                do_get_opts(opts, :no_local, boolean()),
                do_get_opts(opts, :retain_as_published, boolean()),
                do_get_opts(opts, :retain_handling, integer(0..2))
              ])
            }
          end)
          |> fixed_list()

        fixed_list([{:topics, topics_with_opts} | Enum.map(values, &constant(&1))])
      end

      defp do_get_opts(opts, key, default) do
        generator =
          case Keyword.get(opts, key) do
            nil -> default
            %StreamData{} = generator -> generator
            otherwise -> constant(otherwise)
          end

        {key, generator}
      end

      defp gen_properties(values) do
        case Keyword.pop(values, :properties) do
          {nil, values} ->
            properties =
              uniq_list_of(
                frequency([
                  # here we allow stings with a byte size of zero; don't
                  # know if that is a problem according to the spec. Let's
                  # handle that situation just in case:
                  {4, {:user_property, {string(:printable), string(:printable)}}},
                  {1, {:subscription_identifier, integer(1..268_435_455)}}
                ]),
                uniq_fun: &uniq/1,
                max_length: 5
              )

            fixed_list([{:properties, properties} | Enum.map(values, &constant(&1))])

          {_passthrough, _} ->
            constant(values)
        end
      end

      defp uniq({:user_property, _v}), do: :crypto.strong_rand_bytes(2)
      defp uniq({k, _v}), do: k
    end
  end
end
