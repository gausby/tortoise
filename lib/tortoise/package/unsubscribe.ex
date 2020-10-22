defmodule Tortoise.Package.Unsubscribe do
  @moduledoc false

  @opcode 10

  # @allowed_properties [:user_property]

  alias Tortoise.Package

  @type topic :: binary()

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            topics: [topic],
            properties: [{:user_property, {String.t(), String.t()}}]
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 2},
            topics: [],
            identifier: nil,
            properties: []

  @spec decode(binary(), opts :: Keyword.t()) :: t
  def decode(<<@opcode::4, 0b0010::4, payload::binary>>, _opts) do
    with payload <- drop_length(payload),
         <<identifier::big-integer-size(16), rest::binary>> <- payload,
         {properties, topics} = Package.parse_variable_length(rest),
         topic_list <- decode_topics(topics) do
      %__MODULE__{
        identifier: identifier,
        topics: topic_list,
        properties: Package.Properties.decode(properties)
      }
    end
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
    <<topic::binary-size(length), rest::binary>> = rest
    [topic] ++ decode_topics(rest)
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(
          %Package.Unsubscribe{
            identifier: identifier,
            # a valid unsubscribe package has at least one topic filter
            topics: [topic_filter | _]
          } = t,
          _opts
        )
        when identifier in 0x0001..0xFFFF and is_binary(topic_filter) do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16)>>,
          Package.Properties.encode(t.properties),
          Enum.map(t.topics, &Package.length_encode/1)
        ])
      ]
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
        |> bind(&gen_properties/1)
        |> bind(&fixed_map([{:__struct__, type} | for({k, v} <- &1, do: {k, constant(v)})]))
      end

      defp gen_identifier(values) do
        case Keyword.pop(values, :identifier) do
          {nil, values} ->
            fixed_list([
              {:identifier, integer(1..0xFFFF)}
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
                list_of(gen_topic_filter(), min_length: 1, max_length: 5)
              }
              | Enum.map(values, &constant(&1))
            ])

          {[_ | _] = topics, values} ->
            [
              {:topics,
               fixed_list(
                 Enum.map(topics, fn
                   nil ->
                     gen_topic_filter()

                   %StreamData{} = generator ->
                     bind(generator, fn
                       <<topic_filter::binary>> when byte_size(topic_filter) > 1 ->
                         constant(topic_filter)

                       faulty_return ->
                         raise ArgumentError, """
                         Faulty result from user specified topic filter generator #{
                           inspect(generator)
                         }

                         The generator should return a non-empty binary. Instead the generator returned:

                           #{inspect(faulty_return)}
                         """
                     end)

                   <<topic_filter::binary>> ->
                     constant(topic_filter)
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

      defp gen_properties(values) do
        # user properties are the only valid property for unsubscribe
        # packages
        case Keyword.pop(values, :properties) do
          {nil, values} ->
            properties =
              list_of(
                # here we allow stings with a byte size of zero; don't
                # know if that is a problem according to the
                # spec. Let's handle that situation just in case:
                {:user_property, {string(:printable), string(:printable)}},
                max_length: 5
              )

            fixed_list([{:properties, properties} | Enum.map(values, &constant(&1))])

          {_passthrough, _} ->
            constant(values)
        end
      end
    end
  end
end
