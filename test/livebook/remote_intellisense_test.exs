defmodule Livebook.RemoteIntellisenseTest do
  use ExUnit.Case, async: true

  alias Livebook.Intellisense

  @tmp_dir "tmp/test/remote_intellisense"

  # Returns intellisense context resulting from evaluating
  # the given block of code in a fresh context.
  defmacrop eval(do: block) do
    quote do
      block = unquote(Macro.escape(block))
      binding = []
      env = Code.env_for_eval([])
      {value, binding, env} = Code.eval_quoted_with_env(block, binding, env)

      %{
        env: env,
        map_binding: fn fun -> fun.(binding) end
      }
    end
  end

  setup_all do
    {:ok, _pid, node} =
      :peer.start(%{
        name: :remote_runtime,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    {:module, Elixir.RemoteModule, bytecode, _} =
      defmodule Elixir.RemoteModule do
        @compile {:autoload, false}
        @moduledoc """
        RemoteModule module docs
        """

        @doc """
        Hello doc
        """
        def hello(message) do
          message
        end
      end

    false = Code.ensure_loaded?(RemoteModule)

    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    File.write!("#{@tmp_dir}/Elixir.RemoteModule.beam", bytecode)

    elixir_path = :code.lib_dir(:elixir, :ebin)

    :ok = :erpc.call(node, :code, :add_paths, [[~c"#{@tmp_dir}", elixir_path]])
    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
    {:module, RemoteModule} = :erpc.call(node, :code, :load_file, [RemoteModule])
    :loaded = :erpc.call(node, :code, :module_status, [RemoteModule])
    :ok = :erpc.call(node, :application, :load, [:mnesia])

    [node: node]
  end

  describe "intellisense completion for remote nodes" do
    test "do not find the RemoteModule inside the Livebook node" do
      context = eval(do: nil)
      assert [] == Intellisense.get_completion_items("RemoteModule", context, node())
    end

    test "find the RemoteModule and its docs", %{node: node} do
      context = eval(do: nil)

      assert %{
               label: "RemoteModule",
               kind: :module,
               detail: "module",
               documentation: "RemoteModule module docs",
               insert_text: "RemoteModule"
             } in Intellisense.get_completion_items("RemoteModule", context, node)
    end

    test "find RemoteModule exported functions and its docs", %{node: node} do
      context = eval(do: nil)

      assert %{
               label: "hello/1",
               kind: :function,
               detail: "RemoteModule.hello(message)",
               documentation: "Hello doc",
               insert_text: "hello($0)"
             } in Intellisense.get_completion_items("RemoteModule.hel", context, node)
    end

    test "find modules from apps", %{node: node} do
      context = eval(do: nil)

      assert [
               %{
                 label: "all_keys/1",
                 kind: :function,
                 detail: ":mnesia.all_keys/1",
                 documentation: _all_keys_doc,
                 insert_text: "all_keys($0)"
               }
             ] = Intellisense.get_completion_items(":mnesia.all", context, node)
    end

    test "get details", %{node: node} do
      context = eval(do: nil)

      assert %{contents: [content]} = Intellisense.get_details("RemoteModule", 6, context, node)
      assert content =~ "RemoteModule module docs"
    end
  end
end
