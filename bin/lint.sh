rojo sourcemap --output sourcemap.json
luau-lsp analyze --sourcemap sourcemap.json src tests
selene src tests
stylua --check src tests
