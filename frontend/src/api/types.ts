export interface QuantityDto {
  amount: string;
  unit: string;
}

export interface ItemRef {
  type: "product" | "meal";
  id: string;
}
