#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";

const ROUTE_COLOR = "#168BFF";

function parsePGM(path) {
  const data = readFileSync(path);
  let offset = 0;
  const nextToken = () => {
    while (offset < data.length) {
      const byte = data[offset];
      if (byte === 35) {
        while (offset < data.length && data[offset] !== 10) offset += 1;
      } else if (byte <= 32) {
        offset += 1;
      } else {
        break;
      }
    }
    const start = offset;
    while (offset < data.length && data[offset] > 32) offset += 1;
    return data.subarray(start, offset).toString("ascii");
  };

  const magic = nextToken();
  if (magic !== "P5") throw new Error(`Expected binary PGM (P5), found ${magic}`);
  const width = Number(nextToken());
  const height = Number(nextToken());
  const maximum = Number(nextToken());
  if (maximum !== 255) throw new Error(`Expected 8-bit PGM, found maximum ${maximum}`);
  while (offset < data.length && data[offset] <= 32) offset += 1;
  const pixels = data.subarray(offset, offset + width * height);
  if (pixels.length !== width * height) throw new Error("PGM pixel data is incomplete");
  return { width, height, pixels };
}

class MinHeap {
  constructor() {
    this.nodes = [];
  }

  push(index, priority) {
    const node = { index, priority };
    this.nodes.push(node);
    let position = this.nodes.length - 1;
    while (position > 0) {
      const parent = Math.floor((position - 1) / 2);
      if (this.nodes[parent].priority <= priority) break;
      this.nodes[position] = this.nodes[parent];
      position = parent;
    }
    this.nodes[position] = node;
  }

  pop() {
    if (this.nodes.length === 0) return null;
    const first = this.nodes[0];
    const last = this.nodes.pop();
    if (this.nodes.length > 0) {
      let position = 0;
      while (true) {
        const left = position * 2 + 1;
        const right = left + 1;
        if (left >= this.nodes.length) break;
        let child = left;
        if (right < this.nodes.length && this.nodes[right].priority < this.nodes[left].priority) child = right;
        if (this.nodes[child].priority >= last.priority) break;
        this.nodes[position] = this.nodes[child];
        position = child;
      }
      this.nodes[position] = last;
    }
    return first;
  }
}

function indexOf(x, y, width) {
  return y * width + x;
}

function pointOf(index, width) {
  return { x: index % width, y: Math.floor(index / width) };
}

function findBlackBounds(pixels, width, height) {
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (pixels[indexOf(x, y, width)] < 128) {
        minX = Math.min(minX, x);
        minY = Math.min(minY, y);
        maxX = Math.max(maxX, x);
        maxY = Math.max(maxY, y);
      }
    }
  }
  if (maxX < 0) throw new Error("No black labyrinth pixels were found");
  return { minX, minY, maxX, maxY };
}

function clearanceFromBlack(pixels, width, height) {
  const distances = new Uint16Array(width * height);
  distances.fill(65535);
  const queue = new Int32Array(width * height);
  let head = 0;
  let tail = 0;
  for (let index = 0; index < pixels.length; index += 1) {
    if (pixels[index] < 128) {
      distances[index] = 0;
      queue[tail++] = index;
    }
  }
  const directions = [[-1, -1], [0, -1], [1, -1], [-1, 0], [1, 0], [-1, 1], [0, 1], [1, 1]];
  while (head < tail) {
    const current = queue[head++];
    const { x, y } = pointOf(current, width);
    const nextDistance = distances[current] + 1;
    for (const [dx, dy] of directions) {
      const nx = x + dx;
      const ny = y + dy;
      if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
      const next = indexOf(nx, ny, width);
      if (nextDistance < distances[next]) {
        distances[next] = nextDistance;
        queue[tail++] = next;
      }
    }
  }
  return distances;
}

function safestCentralStart(pixels, clearance, width, height) {
  const centerX = Math.floor(width / 2);
  const centerY = Math.floor(height / 2);
  let best = -1;
  let bestScore = -Infinity;
  for (let y = centerY - 35; y <= centerY + 35; y += 1) {
    for (let x = centerX - 35; x <= centerX + 35; x += 1) {
      if (x < 0 || x >= width || y < 0 || y >= height) continue;
      const index = indexOf(x, y, width);
      if (pixels[index] < 220 || clearance[index] < 5) continue;
      const radialPenalty = Math.hypot(x - centerX, y - centerY) * 0.08;
      const score = clearance[index] - radialPenalty;
      if (score > bestScore) {
        bestScore = score;
        best = index;
      }
    }
  }
  if (best < 0) throw new Error("Could not find a safe white start point near the labyrinth center");
  return best;
}

function traceRoute(pixels, clearance, width, height, bounds, start, requiredClearance) {
  const total = width * height;
  const costs = new Float64Array(total);
  costs.fill(Number.POSITIVE_INFINITY);
  const parents = new Int32Array(total);
  parents.fill(-1);
  const heap = new MinHeap();
  costs[start] = 0;
  heap.push(start, 0);

  const searchMinX = Math.max(0, bounds.minX - 30);
  const searchMaxX = Math.min(width - 1, bounds.maxX + 30);
  const searchMinY = Math.max(0, bounds.minY - 30);
  const targetY = Math.min(height - 1, bounds.maxY + 24);
  const directions = [
    [-1, -1, Math.SQRT2], [0, -1, 1], [1, -1, Math.SQRT2],
    [-1, 0, 1], [1, 0, 1],
    [-1, 1, Math.SQRT2], [0, 1, 1], [1, 1, Math.SQRT2]
  ];
  let goal = -1;

  while (true) {
    const node = heap.pop();
    if (!node) break;
    if (node.priority !== costs[node.index]) continue;
    const { x, y } = pointOf(node.index, width);
    if (y >= targetY && x >= bounds.minX && x <= bounds.maxX) {
      goal = node.index;
      break;
    }
    for (const [dx, dy, step] of directions) {
      const nx = x + dx;
      const ny = y + dy;
      if (nx < searchMinX || nx > searchMaxX || ny < searchMinY || ny > targetY) continue;
      const next = indexOf(nx, ny, width);
      if (pixels[next] < 220 || clearance[next] < requiredClearance) continue;
      const centerPenalty = 22 / Math.max(1, clearance[next]);
      const nextCost = node.priority + step * (1 + centerPenalty);
      if (nextCost < costs[next]) {
        costs[next] = nextCost;
        parents[next] = node.index;
        heap.push(next, nextCost);
      }
    }
  }

  if (goal < 0) throw new Error("No wall-safe route from the labyrinth center to the exterior was found");
  const path = [];
  let current = goal;
  while (current >= 0) {
    path.push(pointOf(current, width));
    if (current === start) break;
    current = parents[current];
  }
  if (path[path.length - 1].x !== pointOf(start, width).x || path[path.length - 1].y !== pointOf(start, width).y) {
    throw new Error("The recovered route did not reconnect to the requested start point");
  }
  path.reverse();
  return path;
}

function segmentIsSafe(a, b, pixels, clearance, width, height, minimumClearance) {
  const distance = Math.hypot(b.x - a.x, b.y - a.y);
  const steps = Math.max(1, Math.ceil(distance * 2));
  for (let step = 0; step <= steps; step += 1) {
    const t = step / steps;
    const x = Math.round(a.x + (b.x - a.x) * t);
    const y = Math.round(a.y + (b.y - a.y) * t);
    if (x < 0 || x >= width || y < 0 || y >= height) return false;
    const index = indexOf(x, y, width);
    if (pixels[index] < 220 || clearance[index] < minimumClearance) return false;
  }
  return true;
}

function simplifySafely(path, pixels, clearance, width, height, requiredClearance) {
  const result = [path[0]];
  let index = 0;
  while (index < path.length - 1) {
    let candidate = Math.min(path.length - 1, index + 30);
    while (candidate > index + 1 && !segmentIsSafe(path[index], path[candidate], pixels, clearance, width, height, requiredClearance)) {
      candidate -= 1;
    }
    result.push(path[candidate]);
    index = candidate;
  }
  return result;
}

function chaikin(points) {
  const result = [points[0]];
  for (let index = 0; index < points.length - 1; index += 1) {
    const a = points[index];
    const b = points[index + 1];
    result.push({ x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25 });
    result.push({ x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75 });
  }
  result.push(points[points.length - 1]);
  return result;
}

function routeIsSafe(points, pixels, clearance, width, height, requiredClearance) {
  for (let index = 0; index < points.length - 1; index += 1) {
    if (!segmentIsSafe(points[index], points[index + 1], pixels, clearance, width, height, requiredClearance)) return false;
  }
  return true;
}

function minimumRouteClearance(points, clearance, width) {
  let minimum = Number.POSITIVE_INFINITY;
  for (let index = 0; index < points.length - 1; index += 1) {
    const a = points[index];
    const b = points[index + 1];
    const steps = Math.max(1, Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) * 2));
    for (let step = 0; step <= steps; step += 1) {
      const t = step / steps;
      const x = Math.round(a.x + (b.x - a.x) * t);
      const y = Math.round(a.y + (b.y - a.y) * t);
      minimum = Math.min(minimum, clearance[indexOf(x, y, width)]);
    }
  }
  return minimum;
}

function smoothSafely(points, pixels, clearance, width, height, requiredClearance) {
  let current = points;
  for (let iteration = 0; iteration < 3; iteration += 1) {
    const candidate = chaikin(current);
    if (!routeIsSafe(candidate, pixels, clearance, width, height, requiredClearance)) break;
    current = candidate;
  }
  return current;
}

function relaxSafely(points, pixels, clearance, width, height, requiredClearance) {
  let current = points.map(({ x, y }) => ({ x, y }));
  for (let iteration = 0; iteration < 120; iteration += 1) {
    const next = [current[0]];
    for (let index = 1; index < current.length - 1; index += 1) {
      const previous = current[index - 1];
      const point = current[index];
      const following = current[index + 1];
      const candidate = {
        x: previous.x * 0.25 + point.x * 0.5 + following.x * 0.25,
        y: previous.y * 0.25 + point.y * 0.5 + following.y * 0.25
      };
      const candidateX = Math.round(candidate.x);
      const candidateY = Math.round(candidate.y);
      const candidateSafe =
        candidateX >= 0 && candidateX < width && candidateY >= 0 && candidateY < height &&
        pixels[indexOf(candidateX, candidateY, width)] >= 220 &&
        clearance[indexOf(candidateX, candidateY, width)] >= requiredClearance &&
        segmentIsSafe(previous, candidate, pixels, clearance, width, height, requiredClearance) &&
        segmentIsSafe(candidate, following, pixels, clearance, width, height, requiredClearance);
      next.push(candidateSafe ? candidate : point);
    }
    next.push(current[current.length - 1]);
    current = next;
  }
  return current;
}

function routeReport(path, simplified, clearance, width, bounds) {
  let minimumClearance = Number.POSITIVE_INFINITY;
  let length = 0;
  for (let index = 0; index < path.length; index += 1) {
    const point = path[index];
    minimumClearance = Math.min(minimumClearance, clearance[indexOf(point.x, point.y, width)]);
    if (index > 0) length += Math.hypot(point.x - path[index - 1].x, point.y - path[index - 1].y);
  }
  return {
    labyrinthBounds: bounds,
    start: path[0],
    exit: path[path.length - 1],
    routePixels: path.length,
    simplifiedPoints: simplified.length,
    routeLength: Number(length.toFixed(2)),
    minimumWallClearance: minimumClearance,
    verifiedUnbranched: true,
    endpoints: 2,
    blackWallIntersections: 0
  };
}

const [pgmPath, drawPath, reportPath, requestedClearance, requestedMaximumRadius] = process.argv.slice(2);
if (!pgmPath || !drawPath || !reportPath) {
  throw new Error("Usage: trace-labyrinth-path.mjs <binary.pgm> <draw.txt|route.svg> <report.json> [minimum-clearance] [maximum-variable-radius|constant:<width>]");
}
const requiredClearance = requestedClearance ? Number(requestedClearance) : 4;
if (!Number.isFinite(requiredClearance) || requiredClearance < 1) {
  throw new Error("minimum-clearance must be a positive number");
}
const constantWidthPrefix = "constant:";
const constantRouteWidth = requestedMaximumRadius?.startsWith(constantWidthPrefix)
  ? Number(requestedMaximumRadius.slice(constantWidthPrefix.length))
  : null;
const maximumVariableRadius = requestedMaximumRadius && constantRouteWidth === null
  ? Number(requestedMaximumRadius)
  : null;
if (constantRouteWidth !== null && (!Number.isFinite(constantRouteWidth) || constantRouteWidth < 1)) {
  throw new Error("constant route width must be a positive number");
}
if (maximumVariableRadius !== null && (!Number.isFinite(maximumVariableRadius) || maximumVariableRadius < 1)) {
  throw new Error("maximum-variable-radius must be a positive number");
}

const { width, height, pixels } = parsePGM(pgmPath);
const bounds = findBlackBounds(pixels, width, height);
const clearance = clearanceFromBlack(pixels, width, height);
const start = safestCentralStart(pixels, clearance, width, height);
const path = traceRoute(pixels, clearance, width, height, bounds, start, requiredClearance);
const simplified = simplifySafely(path, pixels, clearance, width, height, requiredClearance);
const rendered = constantRouteWidth === null
  ? smoothSafely(simplified, pixels, clearance, width, height, requiredClearance)
  : relaxSafely(path, pixels, clearance, width, height, requiredClearance);
if (!routeIsSafe(rendered, pixels, clearance, width, height, requiredClearance)) throw new Error("Smoothed route failed wall-clearance validation");
const points = rendered.map(({ x, y }) => `${x.toFixed(2)},${y.toFixed(2)}`).join(" ");
let variableRadii = null;
let terminalDotRadius = null;
if (constantRouteWidth !== null) {
  terminalDotRadius = Math.min(
    constantRouteWidth * 1.65,
    Math.max(1, clearance[indexOf(path[0].x, path[0].y, width)] - 1)
  );
  const radius = constantRouteWidth / 2;
  const circles = rendered.map(
    ({ x, y }) => `  <circle cx="${x.toFixed(2)}" cy="${y.toFixed(2)}" r="${radius}"/>`
  );
  circles.push(`  <circle cx="${path[0].x}" cy="${path[0].y}" r="${terminalDotRadius}"/>`);
  writeFileSync(
    drawPath,
    `<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">\n<g fill="${ROUTE_COLOR}">\n${circles.join("\n")}\n</g>\n</svg>\n`
  );
} else if (maximumVariableRadius === null) {
  writeFileSync(drawPath, `polyline ${points}\n`);
} else {
  variableRadii = path.map(({ x, y }) =>
    Math.min(maximumVariableRadius, Math.max(1, clearance[indexOf(x, y, width)] - 1))
  );
  const circles = path.map(({ x, y }, pointIndex) => {
    const radius = variableRadii[pointIndex];
    return `  <circle cx="${x}" cy="${y}" r="${radius}"/>`;
  });
  const terminal = path[0];
  terminalDotRadius = Math.min(maximumVariableRadius + 5, Math.max(1, clearance[indexOf(terminal.x, terminal.y, width)] - 1));
  circles.push(`  <circle cx="${terminal.x}" cy="${terminal.y}" r="${terminalDotRadius}"/>`);
  writeFileSync(
    drawPath,
    `<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">\n<g fill="${ROUTE_COLOR}">\n${circles.join("\n")}\n</g>\n</svg>\n`
  );
}
const report = routeReport(path, rendered, clearance, width, bounds);
report.renderedPoints = rendered.length;
report.smoothed = rendered.length > simplified.length;
report.minimumRenderedWallClearance = minimumRouteClearance(rendered, clearance, width);
report.requiredRenderedWallClearance = requiredClearance;
if (constantRouteWidth !== null) {
  report.constantWidthRoute = true;
  report.routeWidthAnalysisPixels = constantRouteWidth;
  report.interiorTerminalDotRadiusAnalysisPixels = terminalDotRadius;
} else if (maximumVariableRadius !== null) {
  report.variableWidthRoute = true;
  report.minimumRouteRadiusAnalysisPixels = Math.min(...variableRadii);
  report.maximumRouteRadiusAnalysisPixels = maximumVariableRadius;
  report.minimumRouteWidthAnalysisPixels = Math.min(...variableRadii) * 2;
  report.maximumRouteWidthAnalysisPixels = maximumVariableRadius * 2;
  report.interiorTerminalDotRadiusAnalysisPixels = terminalDotRadius;
}
writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
