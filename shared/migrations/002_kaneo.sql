-- Preserve historical issues and comments while moving active tracking to Kaneo.
ALTER TABLE repositories ADD COLUMN kaneo_project_url TEXT NOT NULL DEFAULT '';
ALTER TABLE pull_requests ADD COLUMN kaneo_task_url TEXT NOT NULL DEFAULT '';
