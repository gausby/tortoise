defmodule Tortoise311.RegistryTest do
  use ExUnit.Case, async: true
  doctest Tortoise311.Registry

  test "via_name/2", context do
    {mod, name} = {__MODULE__, context.test}

    assert {:via, Registry, {Tortoise311.Registry, {^mod, ^name}}} =
             Tortoise311.Registry.via_name(mod, name)
  end

  test "meta put, get, delete", context do
    key = Tortoise311.Registry.via_name(__MODULE__, context.test)
    value = :crypto.strong_rand_bytes(2)

    assert :error == Tortoise311.Registry.meta(key)
    assert :ok = Tortoise311.Registry.put_meta(key, value)
    assert {:ok, ^value} = Tortoise311.Registry.meta(key)
    assert :ok = Tortoise311.Registry.delete_meta(key)
    assert :error == Tortoise311.Registry.meta(key)
  end
end
