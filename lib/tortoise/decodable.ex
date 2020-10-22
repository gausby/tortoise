defprotocol Tortoise.Decodable do
  @moduledoc false

  def decode(data, opts \\ [])
end

defimpl Tortoise.Decodable, for: BitString do
  alias Tortoise.Package.{
    Connect,
    Connack,
    Publish,
    Puback,
    Pubrec,
    Pubrel,
    Pubcomp,
    Subscribe,
    Suback,
    Unsubscribe,
    Unsuback,
    Pingreq,
    Pingresp,
    Disconnect,
    Auth
  }

  def decode(<<1::4, _::4, _::binary>> = data, opts), do: Connect.decode(data, opts)
  def decode(<<2::4, _::4, _::binary>> = data, opts), do: Connack.decode(data, opts)
  def decode(<<3::4, _::4, _::binary>> = data, opts), do: Publish.decode(data, opts)
  def decode(<<4::4, _::4, _::binary>> = data, opts), do: Puback.decode(data, opts)
  def decode(<<5::4, _::4, _::binary>> = data, opts), do: Pubrec.decode(data, opts)
  def decode(<<6::4, _::4, _::binary>> = data, opts), do: Pubrel.decode(data, opts)
  def decode(<<7::4, _::4, _::binary>> = data, opts), do: Pubcomp.decode(data, opts)
  def decode(<<8::4, _::4, _::binary>> = data, opts), do: Subscribe.decode(data, opts)
  def decode(<<9::4, _::4, _::binary>> = data, opts), do: Suback.decode(data, opts)
  def decode(<<10::4, _::4, _::binary>> = data, opts), do: Unsubscribe.decode(data, opts)
  def decode(<<11::4, _::4, _::binary>> = data, opts), do: Unsuback.decode(data, opts)
  def decode(<<12::4, _::4, _::binary>> = data, opts), do: Pingreq.decode(data, opts)
  def decode(<<13::4, _::4, _::binary>> = data, opts), do: Pingresp.decode(data, opts)
  def decode(<<14::4, _::4, _::binary>> = data, opts), do: Disconnect.decode(data, opts)
  def decode(<<15::4, _::4, _::binary>> = data, opts), do: Auth.decode(data, opts)
end

defimpl Tortoise.Decodable, for: List do
  def decode(data, opts) do
    data
    |> IO.iodata_to_binary()
    |> Tortoise.Decodable.decode(opts)
  end
end
