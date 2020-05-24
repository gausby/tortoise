defmodule Tortoise.Package.Publish do
  @moduledoc false

  @opcode 3

  @allowed_properties [
    :payload_format_indicator,
    :message_expiry_interval,
    :topic_alias,
    :response_topic,
    :correlation_data,
    :user_property,
    :subscription_identifier,
    :content_type
  ]

  alias Tortoise.Package

  @type t :: %__MODULE__{
          __META__: Package.Meta.t(),
          topic: Tortoise.topic() | nil,
          qos: Tortoise.qos(),
          payload: Tortoise.payload(),
          identifier: Tortoise.package_identifier(),
          dup: boolean(),
          retain: boolean(),
          properties: [{any(), any()}]
        }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            identifier: nil,
            topic: nil,
            payload: nil,
            qos: 0,
            dup: false,
            retain: false,
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::1, 0::2, retain::1, length_prefixed_payload::binary>>) do
    payload = drop_length_prefix(length_prefixed_payload)
    {topic, properties, payload} = decode_message(payload)

    Package.Meta.infer(%__MODULE__{
      qos: 0,
      identifier: nil,
      dup: false,
      retain: retain == 1,
      topic: topic,
      payload: payload,
      properties: properties
    })
  end

  def decode(
        <<@opcode::4, dup::1, qos::integer-size(2), retain::1, length_prefixed_payload::binary>>
      ) do
    payload = drop_length_prefix(length_prefixed_payload)
    {topic, identifier, properties, payload} = decode_message_with_id(payload)

    Package.Meta.infer(%__MODULE__{
      qos: qos,
      identifier: identifier,
      dup: dup == 1,
      retain: retain == 1,
      topic: topic,
      payload: payload,
      properties: properties
    })
  end

  defp drop_length_prefix(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  defp decode_message(<<topic_length::big-integer-size(16), package::binary>>) do
    <<topic::binary-size(topic_length), rest::binary>> = package
    {properties, payload} = Package.parse_variable_length(rest)
    properties = Package.Properties.decode(properties)

    case Keyword.split(properties, @allowed_properties) do
      {^properties, []} ->
        {topic, properties, nullify(payload)}

      {_, _violations} ->
        # todo !
        {topic, properties, nullify(payload)}
    end
  end

  defp decode_message_with_id(<<topic_length::big-integer-size(16), package::binary>>) do
    <<topic::binary-size(topic_length), identifier::big-integer-size(16), rest::binary>> = package
    {properties, payload} = Package.parse_variable_length(rest)
    properties = Package.Properties.decode(properties)

    case Keyword.split(properties, @allowed_properties) do
      {^properties, []} ->
        {topic, identifier, properties, nullify(payload)}

      {_, _violations} ->
        # todo !
        {topic, identifier, properties, nullify(payload)}
    end
  end

  defp nullify(""), do: nil
  defp nullify(payload), do: payload

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(%Package.Publish{identifier: nil, qos: 0} = t) do
      [
        Package.Meta.encode(%{t.__META__ | flags: encode_flags(t)}),
        Package.variable_length_encode([
          Package.length_encode(t.topic),
          Package.Properties.encode(t.properties),
          encode_payload(t)
        ])
      ]
    end

    def encode(%Package.Publish{identifier: identifier, qos: qos} = t)
        when identifier in 0x0001..0xFFFF and qos in 1..2 do
      [
        Package.Meta.encode(%{t.__META__ | flags: encode_flags(t)}),
        Package.variable_length_encode([
          Package.length_encode(t.topic),
          <<identifier::big-integer-size(16)>>,
          Package.Properties.encode(t.properties),
          encode_payload(t)
        ])
      ]
    end

    defp encode_flags(%{dup: dup, qos: qos, retain: retain}) do
      <<flags::4>> = <<flag(dup)::1, qos::integer-size(2), flag(retain)::1>>
      flags
    end

    defp encode_payload(%{payload: nil}), do: ""

    defp encode_payload(%{payload: payload}), do: payload

    defp flag(f) when f in [0, nil, false], do: 0
    defp flag(_), do: 1
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl Tortoise.Generatable do
      import StreamData

      alias Tortoise.Generatable.Topic

      def generate(%type{__META__: _meta} = package) do
        values = package |> Map.from_struct()

        fixed_list(Enum.map(values, &constant(&1)))
        |> bind(&gen_topic/1)
        |> bind(&gen_qos/1)
        |> bind(&gen_retain/1)
        |> bind(&gen_payload/1)
        |> bind(&gen_identifier/1)
        |> bind(&gen_dup/1)
        |> bind(&gen_properties/1)
        |> bind(&update_meta_flags/1)
        |> bind(fn data ->
          fixed_map([
            {:__struct__, type}
            | for({k, v} <- data, do: {k, constant(v)})
          ])
        end)
      end

      defp update_meta_flags(values) do
        {meta, values} = Keyword.pop(values, :__META__)

        qos = Keyword.get(values, :qos)
        retain = Keyword.get(values, :retain)
        dup = Keyword.get(values, :dup)

        <<flags::4>> = <<flag(dup)::1, qos::integer-size(2), flag(retain)::1>>

        fixed_list([
          {:__META__, constant(%{meta | flags: flags})}
          | Enum.map(values, &constant(&1))
        ])
      end

      defp flag(true), do: 1
      defp flag(false), do: 0

      defp gen_qos(values) do
        case Keyword.pop(values, :qos) do
          {nil, values} ->
            fixed_list([
              {constant(:qos), integer(0..2)}
              | Enum.map(values, &constant(&1))
            ])

          {qos, _} when is_integer(qos) and qos in 0..2 ->
            constant(values)
        end
      end

      defp gen_identifier(values) do
        qos = Keyword.get(values, :qos)

        case Keyword.pop(values, :identifier) do
          {nil, values} when qos > 0 ->
            fixed_list([
              {:identifier, integer(1..0xFFFF)}
              | Enum.map(values, &constant(&1))
            ])

          {nil, values} when qos == 0 ->
            fixed_list([
              {:identifier, nil}
              | Enum.map(values, &constant(&1))
            ])

          {id, _} when qos > 0 and is_integer(id) and id in 1..0xFFFF ->
            constant(values)
        end
      end

      defp gen_topic(values) do
        case Keyword.pop(values, :topic) do
          {nil, values} ->
            bind(Topic.gen_topic(), fn topic_levels ->
              fixed_list([
                {:topic, constant(Enum.join(topic_levels, "/"))}
                | Enum.map(values, &constant(&1))
              ])
            end)

          {<<_::binary>>, _values} ->
            constant(values)
        end
      end

      defp gen_retain(values) do
        case Keyword.pop(values, :retain) do
          {nil, values} ->
            fixed_list([{:retain, boolean()} | Enum.map(values, &constant(&1))])

          {retain, _} when is_boolean(retain) ->
            constant(values)
        end
      end

      defp gen_payload(values) do
        case Keyword.pop(values, :payload) do
          {nil, values} ->
            fixed_list([
              {:payload, binary(min_length: 1)}
              | Enum.map(values, &constant(&1))
            ])

          {payload, _} when is_binary(payload) ->
            constant(values)
        end
      end

      defp gen_dup(values) do
        qos = Keyword.get(values, :qos)

        case Keyword.pop(values, :dup) do
          {nil, values} when qos > 0 ->
            fixed_list([{:dup, boolean()} | Enum.map(values, &constant(&1))])

          {nil, values} when qos == 0 ->
            fixed_list([{:dup, constant(false)} | Enum.map(values, &constant(&1))])

          {dup, _} when is_boolean(dup) ->
            constant(values)
        end
      end

      defp gen_properties(values) do
        case Keyword.pop(values, :properties) do
          {nil, values} ->
            properties =
              uniq_list_of(
                one_of([
                  # here we allow stings with a byte size of zero; don't
                  # know if that is a problem according to the spec. Let's
                  # handle that situation just in case:
                  {constant(:user_property), {string(:printable), string(:printable)}}
                ]),
                uniq_fun: &uniq/1,
                max_length: 5
              )

            fixed_list([
              {constant(:properties), properties}
              | Enum.map(values, &constant(&1))
            ])

          {_passthrough, _} ->
            constant(values)
        end
      end

      defp uniq({:user_property, _v}), do: :crypto.strong_rand_bytes(2)
      defp uniq({k, _v}), do: k
    end
  end
end
