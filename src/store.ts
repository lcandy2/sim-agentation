import { mkdirSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

export type Status = 'pending' | 'acknowledged' | 'resolved' | 'dismissed';

export interface NodeSummary {
  role: string;
  label: string | null;
  identifier: string | null;
  value: string | null;
  title: string | null;
  frame: { x: number; y: number; width: number; height: number };
}

export interface SourceRef {
  name: string;
  file: string;
  line: number;
}

export interface Reply {
  from: 'agent' | 'human';
  message: string;
  at: string;
}

export interface Annotation {
  id: string;
  createdAt: string;
  updatedAt: string;
  status: Status;
  comment: string;
  kind: 'element' | 'area';
  device: { udid: string; name: string | null; runtime: string | null };
  rect: { x: number; y: number; width: number; height: number };
  target: NodeSummary | null;
  targetPath: string[];
  inside: NodeSummary[];
  screen: { app: string | null; headings: string[] };
  app: { bundleId: string | null; name: string | null };
  source: SourceRef[]; // innermost first, from SimAgentationPlus tags
  views: string[]; // app-defined view classes around the box, innermost first
  controller: string | null; // app-defined view controller that owns the box
  images: { full: string; crop: string };
  replies: Reply[];
  resolution: string | null;
}

export const HOME = process.env.SIM_AGENTATION_HOME || join(homedir(), '.sim-agentation');
const FILE = join(HOME, 'annotations.json');
export const IMAGES = join(HOME, 'images');

mkdirSync(IMAGES, { recursive: true });

function load(): Annotation[] {
  if (!existsSync(FILE)) return [];
  try {
    return JSON.parse(readFileSync(FILE, 'utf8'));
  } catch {
    return [];
  }
}

let annotations = load();
const listeners = new Set<() => void>();

function save() {
  writeFileSync(FILE, JSON.stringify(annotations, null, 2));
  for (const fn of listeners) fn();
}

export function onChange(fn: () => void) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function list(status?: Status) {
  return status ? annotations.filter((a) => a.status === status) : annotations;
}

export function get(id: string) {
  return annotations.find((a) => a.id === id || a.id.startsWith(id)) ?? null;
}

export function newId() {
  return randomUUID().slice(0, 8);
}

export function add(a: Annotation) {
  annotations.push(a);
  save();
  return a;
}

export function update(id: string, patch: Partial<Annotation>, reply?: Reply) {
  const a = get(id);
  if (!a) return null;
  Object.assign(a, patch, { updatedAt: new Date().toISOString() });
  if (reply) a.replies.push(reply);
  save();
  return a;
}

export function clearFinished() {
  annotations = annotations.filter((a) => a.status === 'pending' || a.status === 'acknowledged');
  save();
}
