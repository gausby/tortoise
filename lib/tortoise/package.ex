defmodule Tortoise.Package do
  @moduledoc false

  alias Tortoise.Package

  @opaque message ::
            Package.Connect.t()
            | Package.Connack.t()
            | Package.Publish.t()
            | Package.Puback.t()
            | Package.Pubrec.t()
            | Package.Pubrel.t()
            | Package.Pubcomp.t()
            | Package.Subscribe.t()
            | Package.Suback.t()
            | Package.Unsubscribe.t()
            | Package.Unsuback.t()
            | Package.Pingreq.t()
            | Package.Pingresp.t()
            | Package.Disconnect.t()

  defdelegate encode(data), to: Tortoise.Encodable
  defdelegate decode(data), to: Tortoise.Decodable

  @doc false
  def length_encode(data) do
    length_prefix = <<byte_size(data)::big-integer-size(16)>>
    [length_prefix, data]
  end

  @doc false
  def variable_length(n) do
    remaining_length(n)
  end

  @doc false
  def variable_length_encode(data) when is_list(data) do
    length_prefix = data |> IO.iodata_length() |> remaining_length()
    length_prefix ++ data
  end

  @highbit 0b10000000
  defp remaining_length(n) when n < @highbit, do: [<<0::1, n::7>>]

  defp remaining_length(n) do
    [<<1::1, rem(n, @highbit)::7>>] ++ remaining_length(div(n, @highbit))
  end

  @doc false
  def drop_length_prefix(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end
end
