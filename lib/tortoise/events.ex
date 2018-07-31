defmodule Tortoise.Events do
  @moduledoc """

  """

  @types [:connection, :ping_response]

  def register(client_id, type) when type in @types do
    {:ok, _pid} = Registry.register(__MODULE__, type, client_id)
  end

  def unregister(client_id, type) when type in @types do
    :ok = Registry.unregister_match(__MODULE__, type, client_id)
  end

  @doc false
  def dispatch(client_id, type, value) when type in @types do
    :ok =
      Registry.dispatch(__MODULE__, type, fn subscribers ->
        for {pid, ^client_id} <- subscribers do
          Kernel.send(pid, {{Tortoise, client_id}, type, value})
        end
      end)
  end
end
