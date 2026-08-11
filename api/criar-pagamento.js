export default async function handler(req, res) {
  const { valor, email, orderId } = req.body || {}

  const r = await fetch('https://api.mercadopago.com/v1/payments', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + process.env.MP_ACCESS_TOKEN,
      'Content-Type': 'application/json',
      'X-Idempotency-Key': orderId || String(Date.now())
    },
    body: JSON.stringify({
      transaction_amount: Number(valor),
      payment_method_id: 'pix',
      description: 'Compra ContaHub ' + (orderId || ''),
      payer: { email: email || 'cliente@contahub.app' },
      external_reference: orderId || String(Date.now())
    })
  })

  const d = await r.json()
  if (!d.point_of_interaction) return res.status(400).json({ erro: d })

  res.json({
    id: d.id,
    qrCode: d.point_of_interaction.transaction_data.qr_code,
    qrBase64: d.point_of_interaction.transaction_data.qr_code_base64
  })
}
