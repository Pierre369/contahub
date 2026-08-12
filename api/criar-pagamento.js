export default async function handler(req, res) {
  // ===== CRIAR PAGAMENTO PIX =====
  if (req.method !== 'POST') {
    return res.status(405).json({ erro: 'Método não permitido' })
  }
  
  const { valor, email, orderId } = req.body || {}
  
  // Validações
  if (!orderId) {
    return res.status(400).json({ erro: 'orderId é obrigatório' })
  }
  
  const valorNum = Number(valor)
  if (!valorNum || valorNum <= 0 || valorNum > 100000) {
    return res.status(400).json({ erro: 'Valor deve ser numérico, maior que 0 e menor ou igual a 100000' })
  }
  
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
  if (!email || !emailRegex.test(email)) {
    return res.status(400).json({ erro: 'Email inválido' })
  }
  
  const r = await fetch('https://api.mercadopago.com/v1/payments', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + process.env.MP_ACCESS_TOKEN,
      'Content-Type': 'application/json',
      'X-Idempotency-Key': orderId
    },
    body: JSON.stringify({
      transaction_amount: valorNum,
      payment_method_id: 'pix',
      description: 'Compra ContaHub ' + orderId,
      payer: { email: email },
      external_reference: orderId
    })
  })
  
  const d = await r.json()
  if (!d.point_of_interaction) {
    return res.status(400).json({ erro: d.message || d.error || JSON.stringify(d) })
  }
  
  res.json({
    id: d.id,
    qrCode: d.point_of_interaction.transaction_data.qr_code,
    qrBase64: d.point_of_interaction.transaction_data.qr_code_base64
  })
}
