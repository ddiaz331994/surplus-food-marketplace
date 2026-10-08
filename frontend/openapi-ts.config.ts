import { defineConfig } from '@hey-api/openapi-ts'

// Regenerate after backend API changes:
//   cd backend && uv run python manage.py spectacular --file openapi.yaml
//   cd frontend && npm run gen:api
export default defineConfig({
  input: '../backend/openapi.yaml',
  output: 'src/api/generated',
  plugins: ['@hey-api/client-fetch', '@tanstack/react-query'],
})
