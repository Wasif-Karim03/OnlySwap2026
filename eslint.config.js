// Flat ESLint config. Extends eslint-config-expo and turns off rules that fight Prettier
// (eslint-config-prettier), so formatting is owned entirely by Prettier.
const { defineConfig } = require('eslint/config');
const expoConfig = require('eslint-config-expo/flat');
const prettier = require('eslint-config-prettier');

module.exports = defineConfig([
  expoConfig,
  prettier,
  {
    ignores: ['dist/*', '.expo/*', 'node_modules/*'],
  },
]);
