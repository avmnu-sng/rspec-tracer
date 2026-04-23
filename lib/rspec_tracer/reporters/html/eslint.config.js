import js from '@eslint/js';
import react from 'eslint-plugin-react';
import reactHooks from 'eslint-plugin-react-hooks';
import prettier from 'eslint-config-prettier';
import globals from 'globals';

// Flat config for ESLint 10. Targets the Preact+JSX source under
// src/; everything else in this subdir is config or generated.
// eslint-plugin-react is used in "preact/classic-runtime" mode - we
// don't import React, Preact's pragma is auto-injected by
// @preact/preset-vite via Babel, so `react/react-in-jsx-scope` is off.
// eslint-config-prettier disables stylistic rules that would fight
// Prettier's formatter.
export default [
  {
    ignores: ['dist/**', 'node_modules/**', 'coverage/**'],
  },
  js.configs.recommended,
  {
    files: ['src/**/*.{js,jsx}'],
    plugins: {
      react,
      'react-hooks': reactHooks,
    },
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: 'module',
      parserOptions: {
        ecmaFeatures: { jsx: true },
      },
      globals: {
        ...globals.browser,
      },
    },
    settings: {
      // Preact has no React version; pin a stable React-parity string
      // to silence eslint-plugin-react's detection warning.
      react: { version: '18.3', pragma: 'h', pragmaFrag: 'Fragment' },
    },
    rules: {
      ...react.configs.flat.recommended.rules,
      ...reactHooks.configs.recommended.rules,
      'react/react-in-jsx-scope': 'off',
      'react/jsx-uses-react': 'off',
      'react/prop-types': 'off',
      'react/no-unknown-property': ['error', { ignore: ['class'] }],
      'no-console': ['warn', { allow: ['warn', 'error'] }],
      'no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    },
  },
  {
    files: ['vite.config.js', 'eslint.config.js'],
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: 'module',
      globals: {
        ...globals.node,
      },
    },
  },
  prettier,
];
