export default async function handler(req, res) {
  const id = req.query.id
  if (!id) return res.status(400).json({ erro: 'id obrigatório' })

  const r = await fetch('https://api.mercadopago.com/v1/payments/' + id, {
    headers: { Authorization: 'Bearer ' + process.env.MP_ACCESS_TOKEN }
  })
  const d = await r.json()

  res.json({ status: d.status })
}
