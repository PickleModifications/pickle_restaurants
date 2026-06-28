import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function money(n: number | undefined | null) {
  const v = Math.round(Number(n || 0));
  return "$" + v.toLocaleString("en-US");
}
