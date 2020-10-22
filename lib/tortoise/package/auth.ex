defmodule Tortoise.Package.Auth do
  @moduledoc false

  @opcode 15

  # @allowed_properties [:authentication_method, :authentication_data, :reason_string, :user_property]

  alias Tortoise.Package

  @type reason :: :success | :continue_authentication | :re_authenticate

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            reason: reason(),
            properties: [{any(), any()}]
          }
  @enforce_keys [:reason]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            reason: nil,
            properties: []

  @spec decode(binary(), opts :: Keyword.t()) :: t
  def decode(<<@opcode::4, 0::4, 0>>, _opts) do
    %__MODULE__{reason: coerce_reason_code(0x00)}
  end

  def decode(<<@opcode::4, 0::4, variable_header::binary>>, _opts) do
    <<reason_code::8, properties::binary>> = Package.drop_length_prefix(variable_header)

    %__MODULE__{
      reason: coerce_reason_code(reason_code),
      properties: Package.Properties.decode(properties)
    }
  end

  defp coerce_reason_code(reason_code) do
    case reason_code do
      0x00 -> :success
      0x18 -> :continue_authentication
      0x19 -> :re_authenticate
    end
  end

  defimpl Tortoise.Encodable do
    def encode(%Package.Auth{reason: :success, properties: []} = t, _opts) do
      [Package.Meta.encode(t.__META__), 0]
    end

    def encode(%Package.Auth{reason: reason} = t, _opts)
        when reason in [:success, :continue_authentication, :re_authenticate] do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<to_reason_code(t.reason)::8>>,
          Package.Properties.encode(t.properties)
        ])
      ]
    end

    defp to_reason_code(reason) do
      case reason do
        :success -> 0x00
        :continue_authentication -> 0x18
        :re_authenticate -> 0x19
      end
    end
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl Tortoise.Generatable do
      import StreamData

      def generate(%type{__META__: _meta} = package) do
        values = package |> Map.from_struct()

        fixed_list(Enum.map(values, &constant(&1)))
        |> bind(&gen_reason/1)
        |> bind(&gen_properties/1)
        |> bind(&fixed_map([{:__struct__, type} | for({k, v} <- &1, do: {k, constant(v)})]))
      end

      @reasons [
        :success,
        :continue_authentication,
        :re_authenticate
      ]

      defp gen_reason(values) do
        case Keyword.pop(values, :reason) do
          {nil, values} ->
            fixed_list([{:reason, one_of(@reasons)} | Enum.map(values, &constant(&1))])

          {reason, _} when reason in @reasons ->
            constant(values)
        end
      end

      # If the initial CONNECT packet included an Authentication
      # Method property then all AUTH packets, and any successful
      # CONNACK packet MUST include an Authentication Method Property
      # with the same value as in the CONNECT packet [MQTT-4.12.0-5].

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
                  # TODO authentication method should always be present
                  {1, {:authentication_method, string(:printable)}},
                  {1, {:authentication_data, string(:printable)}},
                  {1, {:reason_string, string(:printable)}}
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
